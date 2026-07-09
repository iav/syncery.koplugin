-- =============================================================================
-- syncery_transports/plugin_sync.lua
-- =============================================================================
--
-- The plugin-facing transport glue: the cloud upload/schedule logic
-- for the plugin.
--
-- WHY THIS IS A SEPARATE MODULE, NOT METHODS ON THE ORCHESTRATOR
--
-- The obvious relocation target, `syncery_transports/orchestrator.lua`,
-- is the transport
-- *contract* Orchestrator — a deliberately plugin-agnostic, `.new()`-
-- constructed, fake-tested class that holds registered transports and
-- nothing else.  The helpers below are the opposite: they read many
-- distinct plugin members (`plugin._transport`, `plugin.use_cloud`,
-- `plugin:getCurrentState`, the cloud status fields —).  Making them
-- methods of the contract Orchestrator would pull plugin concerns into
-- a module whose entire value is being plugin-agnostic.
--
-- So the ad-hoc transport glue lives in a new sibling module instead,
-- out of main.lua.  Every function here takes the plugin instance as
-- its first parameter — the exact pattern `syncery_lifecycle/teardown.lua`
-- already uses.
--
-- PUBLIC SURFACE
--
--   PluginSync.schedule_cloud_upload(plugin, state)
--   PluginSync.do_cloud_upload(plugin, state)
--
-- main.lua keeps one-line delegator methods (`_scheduleCloudUpload`, etc.)
-- so existing call sites — `_save`, `teardown.lua` — are unchanged.
--
-- =============================================================================


local logger        = require("logger")
local Util          = require("syncery_util")
local Settings      = require("syncery_settings")
local AnnPaths      = require("syncery_ann/paths")
local ProgressPaths = require("syncery_progress/paths")
local ProgressStateStore = require("syncery_progress/state_store")
local I18n          = require("syncery_i18n")
local StateStore    = require("syncery_ann/state_store")
local sha2          = require("ffi/sha2")

local _ = I18n.translate


local PluginSync = {}


-- ----------------------------------------------------------------------------
-- schedule_cloud_upload — debounced cloud upload.  Cheap when cloud is
-- off; the work happens only on the timer fire, not on every save.
-- ----------------------------------------------------------------------------
function PluginSync.schedule_cloud_upload(plugin, state)
    if not plugin.use_cloud or not state then return end
    if not Settings.is_cloud_configured() then return end

    plugin:_schedule("_cloud_upload_action", plugin.cloud_upload_delay, function()
        PluginSync.do_cloud_upload(plugin, state)
    end)
end


-- ----------------------------------------------------------------------------
-- do_cloud_upload — upload progress + annotations for the current book.
-- When offline, schedules a wifi-backoff retry instead of a bare return.
-- ----------------------------------------------------------------------------
function PluginSync.do_cloud_upload(plugin, state)
    if not plugin.use_cloud then return end
    if not plugin._transport then return end
    if not Settings.is_cloud_configured() then
        return
    end
    state = state or plugin:getCurrentState()
    if not state or not plugin:_isFileTypeSynced(state.file) then return "skipped" end

    -- Gate on CLOUD reachability (real internet + a bounded probe to the
    -- configured server), not the link-only `_isNetworkOnline`: KOReader runs
    -- the WebDAV/Dropbox transfer synchronously on the UI thread, so an
    -- enabled-but-unreachable cloud would freeze the UI.  Unreachable — defer
    -- via the cloud-scoped backoff (which re-probes reachability on retry).
    if not plugin:_isCloudReachable() then
        plugin._cloud_wifi_backoff:attempt{
            label = "cloud upload",
            run   = function() PluginSync.do_cloud_upload(plugin, state) end,
        }
        return "deferred"
    end

    -- The cloud transport reads each file's content from disk inside
    -- its push(); we build the entries list and hand it to the bridge,
    -- which derives book_id internally.  Reading the content here means
    -- a single read per save (no double-open).
    local entries = {}
    local p_path = ProgressPaths.shared_progress_path(state.file)
    local a_path = AnnPaths.shared_annotations_path(state.file)

    if p_path then
        local content
        local f = io.open(p_path, "rb")
        if f then
            content = f:read("*a")
            f:close()
        end
        -- Bootstrap a fresh-device PULL of the peer's reading position, exactly
        -- like the annotations path below.  With no local progress file the
        -- bidirectional cloud sync would skip progress entirely (push and pull
        -- are ONE op -- both need staged content), so a device opening a book
        -- for the FIRST time never DOWNLOADS the peer's position at open.  It
        -- would arrive only on the next debounced upload AFTER our own autosave
        -- creates the file -- up to cloud_upload_delay (60 s) later, far too
        -- late for the open-moment jump (the annotations path already pulls at
        -- open, so the reader sees fresh notes but a stale position).  Stage a
        -- canonical EMPTY envelope (our no-opinion side of the per-device
        -- merge) when progress sync is on; the merge pulls the remote position
        -- in and on_reconciled drives checkRemote.  Safe: progress entries
        -- carry no tombstones, so an empty local side yields the remote entries
        -- with no deletions.
        if (not content or content == "") and plugin.sync_progress then
            content = ProgressStateStore.empty_envelope_json()
        end
        if content and content ~= "" then
            table.insert(entries, { kind = "progress", content = content })
        end
    end
    if a_path then
        local content
        local f = io.open(a_path, "rb")
        if f then
            content = f:read("*a")
            f:close()
        end
        -- Bootstrap a fresh-device PULL.  With no local annotations file the
        -- bidirectional cloud sync would skip this kind entirely (push and pull
        -- are one op; both need staged content), so a device that never
        -- annotated this book would never DOWNLOAD a peer's annotations.  Stage
        -- a canonical EMPTY envelope (this device's no-opinion side of the
        -- 3-way merge) when the annotation/metadata/render master is on; the
        -- merge callback pulls the remote in and reconciles it into the
        -- canonical file (then on_reconciled fires the Reload toast).  Safe:
        -- absent canonical => never synced => the .sync ancestor is also empty
        -- => the merge yields the remote with NO deletions.  Cloud-only:
        -- Syncthing replicates the shared file at FS level.
        if (not content or content == "")
                and (plugin.sync_annotations or plugin.sync_metadata
                     or plugin.sync_render_settings) then
            content = StateStore.empty_envelope_json()
        end
        if content and content ~= "" then
            table.insert(entries, { kind = "annotations", content = content })
        end
    end
    if #entries == 0 then return end

    plugin._transport:push_cloud_files(state.file, entries,
        plugin.ui and plugin.ui.doc_settings)

    -- Record the dispatch time for the upload-debounce window.  Sync
    -- status itself is owned by the orchestrator and read via
    -- `_transport:get_status()`; this module no longer tracks a
    -- per-push ok flag.
    plugin.cloud_last_upload_at = os.time()
    return "dispatched"
end



-- ----------------------------------------------------------------------------
-- pushOpenedBooks -- upload books tracked in the .opened worklist.
-- Read — dedupe — push each unique book — delete (or keep failed retry).
-- ----------------------------------------------------------------------------
local function pushOpenedBooks(plugin, info_fn)
    local path = plugin.state_dir .. ".opened"
    local f = io.open(path, "rb")
    if not f then return end
    local opened = {}
    for line in f:lines() do
        local book = line:gsub("%s+$", "")
        if book ~= "" then opened[book] = true end
    end
    f:close()
    if not next(opened) then return end

    -- If cloud is unreachable, schedule one retry of ALL books via
    -- backoff instead of individually deferring each (which would
    -- drop subsequent attempts while the first retry is in flight).
    if not plugin:_isCloudReachable() then
        plugin._cloud_wifi_backoff:attempt{
            label = "pushOpenedBooks retry",
            run   = function() pushOpenedBooks(plugin, info_fn) end,
        }
        return
    end

    -- Deterministic order: needed for the i/total progress numbering
    -- below, and keeps behaviour reproducible under test.
    local books = {}
    for book in pairs(opened) do books[#books + 1] = book end
    table.sort(books)

    -- info_fn is supplied ONLY by sync_all's interactive Trapper wrap.
    -- The teardown.lua call site passes none, deliberately: that flush
    -- must stay synchronous/inline (Step 5 shuts the transport down
    -- right after, with no future UIManager tick for a suspended
    -- Trapper coroutine to resume on -- see teardown.lua Step 3), so
    -- it gets byte-identical behaviour to before this change, and
    -- plugin.destroyed is still false at that point anyway (it's set
    -- in the SAME synchronous flush, in the step after this one).
    local failed = {}
    local stopped_at
    for i, book in ipairs(books) do
        if info_fn then
            if plugin.destroyed then
                stopped_at = i
                break
            end
            if not info_fn(string.format(_("Uploading %d/%d..."), i, #books)) then
                stopped_at = i
                break
            end
        end
        local ok, status = pcall(PluginSync.do_cloud_upload, plugin, { file = book })
        if not ok or status == "deferred" then
            table.insert(failed, book)
        end
    end
    if stopped_at then
        -- Abort (or plugin destroyed mid-loop): books from here on were
        -- never attempted -- they must stay queued, not be dropped as
        -- if they'd synced.
        for i = stopped_at, #books do
            table.insert(failed, books[i])
        end
    end

    if #failed > 0 then
        local fw = io.open(path, "wb")
        if fw then
            for _, book in ipairs(failed) do
                fw:write(book .. "\n")
            end
            fw:close()
        end
    else
        -- All pushes succeeded; clear .opened
        local fw = io.open(path, "wb")
        if fw then fw:close() end
    end
end

PluginSync.pushOpenedBooks = pushOpenedBooks

-- =============================================================================
-- sync_all — two-phase sync (push + Merkle-manifest pull)
-- =============================================================================
function PluginSync.sync_all(plugin, opts)
    opts = opts or {}
    if plugin._sync_all_in_progress then
        return
    end
    plugin._sync_all_in_progress = true

    local ok, err = pcall(function()
        if plugin.ui and plugin.ui.document then
            plugin:doSave(true, false)
        end

        -- Push (Phase 1) and pull (Phase 2) share ONE Trapper:wrap
        -- spanning both, instead of two separate back-to-back wraps.
        -- Trapper:wrap can return EARLY: the first yield inside the
        -- wrapped function (any Trapper:info() call) hands control
        -- back to UIManager, and the rest of the function resumes
        -- later on a subsequent tick (ui.trapper docs: "This call
        -- should be the last step in some event processing code, as
        -- it may return early"). Two separate wraps in sequence would
        -- let Phase 2's manifest/pull network calls start running
        -- while Phase 1's push loop might still be suspended mid-book
        -- -- the same "code placed AFTER Trapper:wrap may execute
        -- while the wrapped function is only half-done" class already
        -- documented for this project (scattered-metadata advisory).
        -- One wrap enclosing both phases means Phase 2 only starts
        -- once Phase 1 has genuinely, fully returned.
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            Trapper:setPausedText(_("Sync paused."), _("Abort"), _("Continue"))
            local info_fn = function(msg) return Trapper:info(msg) end

            -- Phase 1: Push
            pushOpenedBooks(plugin, info_fn)
            if plugin.destroyed then return end

            -- Phase 2: Pull via Merkle manifest
            local Settings = require("syncery_settings")
            local server = Settings.get_cloud_server()
            if not server then
                return
            end

            local listM = require("syncery_transports/cloud/list")
            local CSProvider = require("syncery_transports/cloud/providers/cloudstorage_provider")
            local cs = CSProvider.resolve_ui_instance(plugin.ui)
            local Util = require("syncery_util")
            local my_device = Util.get_device_id()
            local cjson = require("json")

            if not cs then
                -- Fallback: no Cloud Storage+ plugin
                local orch = plugin._transport and plugin._transport._orch
                if not orch then return end

                -- 2a. Generate and upload manifest via transport
                local my_manifest = listM.generateManifest(plugin)
                local fb_files_hash = nil
                local fb_cache_path = nil
                local fb_skip_upload = false
                local fb_cached_peer_hash = nil
                if my_manifest then
                    local staging_dir = Util.state_dir() .. "cloud_staging/"
                    require("util").makePath(staging_dir)
                    fb_cache_path = staging_dir .. ".manifest_cache"
                    local keys = {}
                    for k in pairs(my_manifest.files) do table.insert(keys, k) end
                    table.sort(keys)
                    local h = sha2.md5; local ctx = h()
                    for _, k in ipairs(keys) do ctx(k); ctx(my_manifest.files[k]) end
                    fb_files_hash = ctx()
                    local cached_our_hash = nil
                    do local fh = io.open(fb_cache_path, "rb")
                        if fh then
                            local line = fh:read("*l")
                            fh:close()
                            if line then
                                local pipe = line:find("|", 1, true)
                                if pipe then
                                    cached_our_hash = line:sub(1, pipe - 1)
                                    fb_cached_peer_hash = line:sub(pipe + 1)
                                else
                                    cached_our_hash = line
                                end
                            end
                        end
                    end
                    fb_skip_upload = (cached_our_hash == fb_files_hash)
                    if not fb_skip_upload then
                        local manifest_json = cjson.encode(my_manifest)
                        local manifest_path = staging_dir .. "syncery-manifest-" .. my_device .. ".txt"
                        local fh = io.open(manifest_path, "wb"); if fh then fh:write(manifest_json); fh:close() end
                        orch:push_book("__manifest__", {
                            payload = { kind = "manifest", book_id = my_device, content = manifest_json }
                        }, { force = true })
                    end
                end

                -- 2b. Discover peers from local staging files
                local peers = {}
                local staging_dir = Util.state_dir() .. "cloud_staging/"
                require("util").makePath(staging_dir)
                local lfs = require("libs/libkoreader-lfs")
                for f in lfs.dir(staging_dir) do
                    local fh = io.open(staging_dir .. f, "rb")
                    if fh then
                        local content = fh:read("*a"); fh:close()
                        if content then
                            local ok_d, data = pcall(cjson.decode, content)
                            if ok_d and data and data.entries then
                                for device_id, _ in pairs(data.entries) do
                                    if device_id ~= my_device then
                                        peers[device_id] = true
                                    end
                                end
                            end
                        end
                    end
                end

                -- 2c. Download peer manifests, compare hashes, sync diff books
                -- Deterministic order (needed for the i/total numbering below);
                -- aborting mid-loop just means fewer peers get checked this
                -- round -- unlike the .opened worklist there's no persistent
                -- per-peer queue to preserve, the next Sync Now redoes the
                -- whole manifest check regardless.
                local peer_ids = {}
                for device_id in pairs(peers) do peer_ids[#peer_ids + 1] = device_id end
                table.sort(peer_ids)

                local changed = {}
                for pi, device_id in ipairs(peer_ids) do
                    if plugin.destroyed then break end
                    if not info_fn(string.format(_("Checking device %d/%d..."), pi, #peer_ids)) then
                        break
                    end
                    local remote_manifest = nil
                    orch:pull_book("__manifest__", {
                        payload = { kind = "manifest", book_id = device_id, content = "{}" }
                    }, function(results)
                        local manifest_path = staging_dir .. "syncery-manifest-" .. device_id .. ".txt"
                        local fh = io.open(manifest_path, "rb")
                        if fh then
                            local raw = fh:read("*a"); fh:close()
                            local ok_d, data = pcall(cjson.decode, raw)
                            if ok_d and data then remote_manifest = data end
                        end
                    end)
                    if remote_manifest and remote_manifest.files and my_manifest and my_manifest.files then
                        local peer_keys = {}
                        for k in pairs(remote_manifest.files) do table.insert(peer_keys, k) end
                        table.sort(peer_keys)
                        local peer_h = sha2.md5; local peer_ctx = peer_h()
                        for _, k in ipairs(peer_keys) do peer_ctx(k); peer_ctx(remote_manifest.files[k]) end
                        local peer_hash = peer_ctx()
                        do local fh = io.open(fb_cache_path, "wb")
                            if fh then fh:write(fb_files_hash .. "|" .. peer_hash); fh:close() end
                        end
                        if not (fb_skip_upload and fb_cached_peer_hash == peer_hash) then
                            for book_id, remote_hash in pairs(remote_manifest.files) do
                                local my_hash = my_manifest.files[book_id]
                                if my_hash and my_hash ~= remote_hash then
                                    local path = listM.resolveBookPath(plugin, book_id)
                                    if path then table.insert(changed, {id = book_id, path = path}) end
                                end
                            end
                        end
                    end
                end

                if #changed > 0 then
                    local function _sync_fallback(changed_books)
                        if not plugin:_isCloudReachable() then
                            plugin._cloud_wifi_backoff:attempt{
                                label = "sync_all fallback retry",
                                run = function()
                                    _sync_fallback(changed_books)
                                end,
                            }
                            return
                        end
                        for i, book in ipairs(changed_books) do
                            if plugin.destroyed then return end
                            if not info_fn(string.format(_("Downloading %d/%d..."), i, #changed_books)) then
                                break
                            end
                            local ok, result = pcall(PluginSync.do_cloud_upload, plugin, { file = book.path })
                            if result == "deferred" then return end
                        end
                    end
                    _sync_fallback(changed)
                end

                Settings.set_last_sync_all_ts(os.time())
                return
            end

            -- Plugin path: Cloud Storage+ available
            if not cs.providers and cs.getProviders then cs:getProviders() end
            local provider = cs.providers and cs.providers[server.type]
            if not provider then return end
            provider.base = server

            -- Refresh Dropbox access token (no-op for WebDAV/FTP)
            pcall(function() provider:genAccessToken() end)

            -- 2a. Generate and upload OUR manifest
            local my_manifest = listM.generateManifest(plugin)
            local pl_files_hash = nil
            local pl_cache_path = nil
            local pl_skip_upload = false
            local pl_cached_peer_hash = nil
            if my_manifest then
                local keys = {}
                for k in pairs(my_manifest.files) do table.insert(keys, k) end
                table.sort(keys)
                local h = sha2.md5; local ctx = h()
                for _, k in ipairs(keys) do ctx(k); ctx(my_manifest.files[k]) end
                pl_files_hash = ctx()
                pl_cache_path = Util.state_dir() .. "cloud_staging/.manifest_cache"
                local cached_our_hash = nil
                do local fh = io.open(pl_cache_path, "rb")
                    if fh then
                        local line = fh:read("*l")
                        fh:close()
                        if line then
                            local pipe = line:find("|", 1, true)
                            if pipe then
                                cached_our_hash = line:sub(1, pipe - 1)
                                pl_cached_peer_hash = line:sub(pipe + 1)
                            else
                                cached_our_hash = line
                            end
                        end
                    end
                end
                pl_skip_upload = (cached_our_hash == pl_files_hash)
                if not pl_skip_upload then
                    listM.uploadManifest(plugin, provider, server, my_manifest)
                end
            end

            -- 2b. List cloud directory for all manifest files
            local ok_list, entries = pcall(provider.listFolder, server.url, true)
            if not ok_list or not entries then
                return
            end

            -- 2c/2d. Collect all peer manifests from the listing
            local manifests_to_check = {}
            for _, e in ipairs(entries) do
                local device_id = e.text:match("^syncery%-manifest%-(.+)%.txt$")
                if device_id and device_id ~= my_device then
                    manifests_to_check[device_id] = true
                end
            end
            -- 2e. Download each remote manifest, compare hashes, build delta list
            -- Deterministic order (needed for the i/total numbering below);
            -- aborting mid-loop just means fewer peers get checked this
            -- round -- there's no persistent per-peer queue to preserve,
            -- the next Sync Now redoes the whole manifest check regardless.
            local peer_ids = {}
            for device_id in pairs(manifests_to_check) do peer_ids[#peer_ids + 1] = device_id end
            table.sort(peer_ids)

            local changed = {}
            for pi, device_id in ipairs(peer_ids) do
                if plugin.destroyed then break end
                if not info_fn(string.format(_("Checking device %d/%d..."), pi, #peer_ids)) then
                    break
                end
                local remote = listM.downloadManifest(plugin, provider, server, device_id)
                if remote and remote.files and my_manifest and my_manifest.files then
                    local peer_keys = {}
                    for k in pairs(remote.files) do table.insert(peer_keys, k) end
                    table.sort(peer_keys)
                    local peer_h = sha2.md5; local peer_ctx = peer_h()
                    for _, k in ipairs(peer_keys) do peer_ctx(k); peer_ctx(remote.files[k]) end
                    local peer_hash = peer_ctx()
                    do local fh = io.open(pl_cache_path, "wb")
                        if fh then fh:write(pl_files_hash .. "|" .. peer_hash); fh:close() end
                    end
                    if not (pl_skip_upload and pl_cached_peer_hash == peer_hash) then
                        for book_id, remote_hash in pairs(remote.files) do
                            local my_hash = my_manifest.files[book_id]
                            if my_hash and my_hash ~= remote_hash then
                                local path = listM.resolveBookPath(plugin, book_id)
                                if path then
                                    table.insert(changed, {id = book_id, path = path})
                                end
                            end
                        end
                    end
                end
            end
            -- 2e. Sync changed books
            local total = #changed

            local function sync_changed(changed_books)
                for i, book in ipairs(changed_books) do
                    if plugin.destroyed then return end
                    if not info_fn(string.format(_("Downloading %d/%d..."), i, total)) then
                        break
                    end
                    local ok, result = pcall(PluginSync.do_cloud_upload, plugin, { file = book.path })
                    if result == "deferred" then return end
                end
            end

            if total > 0 then
                sync_changed(changed)
            end

            Settings.set_last_sync_all_ts(os.time())
        end)
    end)

    plugin._sync_all_in_progress = false

    if not ok then
        logger.warn("Syncery: sync_all error:", tostring(err))
    end
end


return PluginSync
