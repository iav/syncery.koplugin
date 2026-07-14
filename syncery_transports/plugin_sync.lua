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
local function pushOpenedBooks(plugin, info_fn, only_book)
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

    -- Bounded, single-book mode: teardown.lua's Step 3 passes only_book
    -- (the book being closed) instead of flushing the whole worklist --
    -- teardown must stay synchronous/inline with no Trapper progress or
    -- abort (see its own comment), so it must never be on the hook for
    -- an unbounded number of blocking pushes just because OTHER books
    -- were left opened earlier in the session. Those stay queued for
    -- the next full flush (interactive Sync Now, which DOES have a
    -- Trapper dialog). Not present in the worklist -> nothing to do.
    if only_book and not opened[only_book] then return end

    -- If cloud is unreachable, schedule one retry of ALL books via
    -- backoff instead of individually deferring each (which would
    -- drop subsequent attempts while the first retry is in flight).
    if not plugin:_isCloudReachable() then
        plugin._cloud_wifi_backoff:attempt{
            label = "pushOpenedBooks retry",
            run   = function() pushOpenedBooks(plugin, info_fn, only_book) end,
        }
        return
    end

    -- Deterministic order: needed for the i/total progress numbering
    -- below, and keeps behaviour reproducible under test.  In
    -- only_book mode, `untouched` holds every OTHER queued book so the
    -- rewrite below can put them back exactly as they were -- narrowing
    -- to one book must never look like "the rest synced too".
    local books
    local untouched
    if only_book then
        books = { only_book }
        untouched = {}
        for book in pairs(opened) do
            if book ~= only_book then untouched[#untouched + 1] = book end
        end
        table.sort(untouched)
    else
        books = {}
        for book in pairs(opened) do books[#books + 1] = book end
        table.sort(books)
    end

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

    -- Rewrite .opened: untouched books (only_book mode) always stay,
    -- plus whichever processed books failed; omit the ones that
    -- succeeded this round.
    local remaining = untouched or {}
    for _, book in ipairs(failed) do
        remaining[#remaining + 1] = book
    end

    -- Re-entrancy guard (additive, does not touch the logic above):
    -- this whole function can run for a long time -- per-book blocking
    -- network calls, further stretched by Trapper yielding between
    -- them on the interactive info_fn path -- during which KOReader's
    -- single-threaded event loop is free to process OTHER code that
    -- ALSO appends to .opened. Most notably: a teardown flush for a
    -- DIFFERENT book being closed mid-flight is synchronous (by
    -- design -- see teardown.lua's own comment), so it can run to
    -- completion, including its own read-modify-write of .opened,
    -- entirely WHILE this invocation is suspended between two
    -- Trapper:info() calls. Blindly overwriting with `remaining`
    -- (computed only from the snapshot read at the TOP of this
    -- function) would silently drop any book appended during that
    -- window. Re-read fresh here and fold in anything NOT in our
    -- original snapshot (`opened`) -- disjoint from `remaining` by
    -- construction, so this can only ADD entries, never duplicate or
    -- drop one that the logic above already accounted for.
    do
        local rf = io.open(path, "rb")
        if rf then
            for line in rf:lines() do
                local book = line:gsub("%s+$", "")
                if book ~= "" and not opened[book] then
                    remaining[#remaining + 1] = book
                end
            end
            rf:close()
        end
    end

    if #remaining > 0 then
        local fw = io.open(path, "wb")
        if fw then
            for _, book in ipairs(remaining) do
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
-- Cloud prefetch for remote-only books (never opened on this device).
--
-- See docs/CLOUD_PREFETCH_DESIGN.md for the full design and its revision
-- history (v1-v18) -- every constraint referenced in comments below is
-- traced there against the actual code, not assumed.
-- =============================================================================

--- Constraint X: reject any book_id containing anything outside the same
--- safe character class Staging.cloud_name_for already enforces
--- (cloud/staging.lua:83) -- reused deliberately, not reinvented, so the
--- two independent parsers of "what is a legal book_id" cannot drift
--- apart. book_id here comes from untrusted remote input (a cloud
--- directory listing, or a peer's uploaded manifest) -- this must be the
--- first gate applied, before the value touches any path.
local function _isSafeBookId(book_id)
    return type(book_id) == "string" and book_id ~= ""
        and not book_id:match("[^%w%-_]")
end

--- Constraint Q: group a Cloud Storage+ listing's entries by book_id and
--- kind, reusing the exact recognition pattern generateManifest already
--- uses when walking cloud_staging/ (cloud/list.lua:47) -- applied here to
--- the remote listing instead, not reinvented.
---
--- @param entries table listFolder's result -- each entry has .text (name)
---   and .filesize (Constraint D).
--- @return table book_id -> { progress = entry|nil, annotations = entry|nil }
local function _groupRemoteEntries(entries)
    local by_book = {}
    for _, e in ipairs(entries) do
        local kind, book_id = e.text:match("^syncery%-(%a+)%-(.+)%.json$")
        if book_id and _isSafeBookId(book_id)
                and (kind == "progress" or kind == "annotations") then
            by_book[book_id] = by_book[book_id] or {}
            by_book[book_id][kind] = e
        end
    end
    return by_book
end

--- Constraint I / J: validate downloaded (or about-to-be-written) content
--- before it is trusted, then place it at final_path via a temp-write +
--- rename so a reader checking for the file's existence never sees a
--- partial write. Shared by both transport paths (Constraint T's
--- fallback callback calls this too, from Checkpoint 4) -- one validated
--- write implementation, not two independently maintained ones.
---
--- @param content string raw content already read into memory
--- @param final_path string destination path
--- @return boolean ok, string|nil err
local function _validateAndPlace(content, final_path)
    if not content or content == "" then
        return false, "content is empty"
    end
    local ok_json = pcall(require("rapidjson").decode, content)
    if not ok_json then
        return false, "content is not valid JSON"
    end
    local tmp_path = final_path .. ".tmp"
    local wf = io.open(tmp_path, "wb")
    if not wf then return false, "cannot open temp path for write" end
    wf:write(content)
    wf:close()
    local ok_rename, rename_err = os.rename(tmp_path, final_path)
    if not ok_rename then
        os.remove(tmp_path)
        return false, "rename to final path failed: " .. tostring(rename_err)
    end
    return true
end

--- Constraint I/O/P: download one kind for one book_id from the Cloud
--- Storage+ provider into a temp path, validate, then rename into place.
--- io.open(tmp_path, "w") inside downloadFile creates/truncates tmp_path,
--- never final_path -- a failed/interrupted download only ever leaves
--- garbage at tmp_path, never where a later existence check looks.
---
--- @return boolean ok, string|nil err
local function _downloadAndValidate(plugin, provider, server, book_id, kind)
    local prefetch_dir = plugin.state_dir .. "cloud_staging/prefetch/"
    require("util").makePath(prefetch_dir)  -- Constraint P: mkdir -p, no-op if it exists

    local filename   = "syncery-" .. kind .. "-" .. book_id .. ".json"
    local remote_url = server.url .. "/" .. filename  -- Constraint O: matches
                                                        -- the existing manifest-
                                                        -- download convention
    local final_path = prefetch_dir .. filename
    local tmp_path    = final_path .. ".tmp"

    local code = provider.downloadFile(remote_url, tmp_path)
    if code ~= 200 then
        os.remove(tmp_path)
        return false, "download failed: " .. tostring(code)
    end
    local f = io.open(tmp_path, "rb")
    if not f then return false, "cannot open downloaded temp file" end
    local content = f:read("*a")
    f:close()
    os.remove(tmp_path)  -- _validateAndPlace writes its own temp file; this
                         -- one (downloadFile's) is done being read from.
    return _validateAndPlace(content, final_path)
end

-- =============================================================================
-- sync_all — two-phase sync (push + Merkle-manifest pull)
-- =============================================================================
PluginSync._isSafeBookId       = _isSafeBookId
PluginSync._groupRemoteEntries = _groupRemoteEntries
PluginSync._validateAndPlace   = _validateAndPlace
PluginSync._downloadAndValidate = _downloadAndValidate

--- BUGFIX:
--- WebDav.listFolder's own hasProvider filter
--- (plugins/cloudstorage.koplugin/providers/webdav.lua) silently drops any
--- entry with no registered DocumentRegistry provider unless
--- G_reader_settings "show_unsupported" is true. ".txt" (manifest files)
--- already has a registered provider, so that discovery path was never
--- affected and looked like it "just worked" -- but ".json"
--- (progress/annotations) has none, so prefetch's own entries were
--- silently invisible for any user who had not manually enabled this
--- KOReader-wide setting. Borrow the setting for exactly this one call,
--- restore immediately after (pcall-protected around the call itself, so
--- an error inside listFolder cannot skip the restore) -- correct the one
--- call that needs it instead of changing global behavior permanently.
local function _listFolderShowingUnsupported(gset, provider, url, include_folders)
    local prev = gset and gset:isTrue("show_unsupported")
    if gset then gset:saveSetting("show_unsupported", true) end
    local ok, entries = pcall(provider.listFolder, url, include_folders)
    if gset then gset:saveSetting("show_unsupported", prev) end
    return ok, entries
end
PluginSync._listFolderShowingUnsupported = _listFolderShowingUnsupported


--- Constraint C, corrected after real-device testing: this used to
--- reimplement rename-with-fallback from scratch. `Util.move_file`
--- (syncery_util.lua:66) already exists, is already used elsewhere in
--- this codebase for the exact same problem, and is already hardened for
--- the specific Android FUSE/SAF quirk this design's own move step needs
--- (rename can succeed on some cross-volume setups while a plain
--- fallback copy silently truncates -- Util.move_file's own comment:
--- "on an unreliable cross-volume FS... a write can return success yet
--- leave dst TRUNCATED"). Delegate to it instead of maintaining a
--- second, less battle-tested copy of the same logic.
---
--- @return boolean ok, string|nil err
local function _moveOrCopyDelete(src, dst)
    if Util.move_file(src, dst) then return true end
    return false, "Util.move_file failed for " .. tostring(src) .. " -> " .. tostring(dst)
end

--- Constraint M/G/toggle-respecting: move any staged prefetch content for
--- book_id into canonical storage, now that book_file is known (this is
--- called from onReaderReady, where it always is). Safe because an empty
--- local/last-sync map is documented, normal input to Merge.three_way
--- (same reasoning as do_cloud_upload's own bootstrap-empty-envelope
--- path) -- moving staged remote content into an empty canonical slot
--- reaches the same safe outcome one merge cycle earlier.
function PluginSync.apply_staged_prefetch(plugin, book_id, book_file)
    if not _isSafeBookId(book_id) then return end  -- Constraint X, defensive
    if not (plugin and plugin._isFileTypeSynced
            and plugin:_isFileTypeSynced(book_file)) then
        return
    end

    local prefetch_dir = plugin.state_dir .. "cloud_staging/prefetch/"
    local progress_src = prefetch_dir .. "syncery-progress-" .. book_id .. ".json"
    local annot_src     = prefetch_dir .. "syncery-annotations-" .. book_id .. ".json"
    local progress_dst  = ProgressPaths.shared_progress_path(book_file)
    local annot_dst      = AnnPaths.shared_annotations_path(book_file)
    local lfs = Util.get_lfs()
    if not lfs then return end

    -- Constraint M: shared_progress_path/shared_annotations_path can
    -- return nil -- guard explicitly before ever handing a possibly-nil
    -- value to lfs.attributes.
    if plugin.sync_progress and progress_dst
            and not lfs.attributes(progress_dst)
            and lfs.attributes(progress_src) then
        local ok, err = _moveOrCopyDelete(progress_src, progress_dst)
        if not ok then
            logger.warn("Syncery: staged progress apply failed:", err)
        end
    end
    if (plugin.sync_annotations or plugin.sync_metadata or plugin.sync_render_settings)
            and annot_dst
            and not lfs.attributes(annot_dst)
            and lfs.attributes(annot_src) then
        local ok, err = _moveOrCopyDelete(annot_src, annot_dst)
        if not ok then
            logger.warn("Syncery: staged annotations apply failed:", err)
        end
    end
end


PluginSync._moveOrCopyDelete = _moveOrCopyDelete


--- UI visibility helpers (docs/CLOUD_PREFETCH_DESIGN.md, section 4.4).
--- Shared enumerator across Booklist/Progress Browser/Annotation Browser --
--- one enumeration + one title-extraction implementation, not three.

--- Enumerate cloud_staging/prefetch/, grouping by book_id, same recognition
--- and safety-gate pattern as _groupRemoteEntries (Constraint X applied
--- again here -- a future writer into this folder is not assumed to
--- always remember the gate).
---@return table book_id -> { progress = path|nil, annotations = path|nil }
function PluginSync.enumerate_prefetch_staging(plugin)
    local prefetch_dir = plugin.state_dir .. "cloud_staging/prefetch/"
    local lfs = Util.get_lfs()
    local by_book = {}
    if not (lfs and lfs.attributes(prefetch_dir, "mode") == "directory") then
        return by_book
    end
    for f in lfs.dir(prefetch_dir) do
        local kind, book_id = f:match("^syncery%-(%a+)%-(.+)%.json$")
        if book_id and _isSafeBookId(book_id)
                and (kind == "progress" or kind == "annotations") then
            by_book[book_id] = by_book[book_id] or {}
            by_book[book_id][kind] = prefetch_dir .. f
        end
    end
    return by_book
end

--- Extract a display title from a staged progress.json's first `"file"`
--- value's basename, extension stripped. Pattern match on raw text, not a
--- full JSON decode -- only one field is needed, and this may run once per
--- staged book per browser open. Read-only: never writes anything back,
--- so it cannot affect any hash the way an embedded-in-payload title hint
--- would (that alternative was considered and rejected -- see the design
--- doc). Returns nil (never raises) when there is nothing usable.
function PluginSync.extract_title_hint(progress_path)
    if not progress_path then return nil end
    local f = io.open(progress_path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content then return nil end
    local path = content:match('"file"%s*:%s*"([^"]+)"')
    if not path then return nil end
    local base = path:match("([^/\\]+)$") or path
    return (base:gsub("%.%w+$", ""))
end


--- Constraints S/T (design), corrected during implementation: reuses the
--- EXISTING unified dispatch (cloud/transport.lua's cloud_sync, reached
--- via orch:pull_book) with two new kind values
--- ("prefetch_progress"/"prefetch_annotations"), the exact same pattern
--- the existing "manifest" kind already demonstrates -- NOT a
--- hand-rolled SyncServiceAdapter construction, which the design's
--- earlier revisions assumed was necessary before this implementation
--- found otherwise. Bootstraps an empty envelope as the "local" side
--- (same safety reasoning as do_cloud_upload's own fresh-open-pull
--- bootstrap: an empty local map is documented, normal input to
--- Merge.three_way) -- the merge callback (registered in transport.lua)
--- reads the real downloaded content from income_file and places it into
--- cloud_staging/prefetch/ via the shared _validateAndPlace.
local function _prefetchViaFallback(plugin, orch, book_id, kind)
    local content = (kind == "progress")
        and ProgressStateStore.empty_envelope_json()
        or StateStore.empty_envelope_json()
    local pull_kind = (kind == "progress") and "prefetch_progress" or "prefetch_annotations"
    orch:pull_book("__prefetch__", {
        payload = { kind = pull_kind, book_id = book_id, content = content },
    }, function(results)
        -- Fire-and-forget from this call's point of view -- errors are
        -- already logged inside the merge callback / cloud_sync itself;
        -- nothing further to reconcile here (unlike the manifest case,
        -- there is no local file for this caller to read back).
    end)
end
PluginSync._prefetchViaFallback = _prefetchViaFallback


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
            -- Guarded the same way as this codebase's other Trapper
            -- call sites (main.lua's on_progress callback): info_fn is
            -- also captured by pushOpenedBooks' and _sync_fallback's
            -- own backoff-retry closures below, which can fire LATER
            -- from a UIManager:scheduleIn tick (wifi_backoff.lua) --
            -- genuinely outside any coroutine, not just this suspended
            -- one. Trapper:info() yields internally; calling it from
            -- outside a coroutine is exactly what coroutine.isyieldable()
            -- exists to guard against. When not yieldable there's no
            -- Trapper dialog to drive anyway, so "continue" is the only
            -- sane answer -- returning false there would abort a retry
            -- that never even reached Trapper.
            local info_fn = function(msg)
                if not coroutine.isyieldable() then
                    return true
                end
                return Trapper:info(msg)
            end

            -- Everything below runs inside its OWN pcall so that every
            -- early-return path (no server configured, no orch, listFolder
            -- failure, etc.) and any error still falls through to the
            -- Trapper:reset() right after -- otherwise whichever progress
            -- message was last shown (e.g. "Checking device 2/2...") is
            -- left stuck on screen with no confirmation of what happened.
            local body_ok, body_err = pcall(function()

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
                    local staging_dir = plugin.state_dir .. "cloud_staging/"
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
                    -- Record OUR hash now, independent of whether any peer
                    -- is found below: the peer loop's own write (further
                    -- down) already overwrites this with the fuller
                    -- "our_hash|peer_hash" pair when a peer IS found, but
                    -- with zero peers that write never runs -- without
                    -- this line, fb_skip_upload would never see a cache
                    -- hit and would re-upload the SAME unchanged manifest
                    -- on every single sync_all call, indefinitely, until
                    -- a peer eventually appears.
                    do local fh = io.open(fb_cache_path, "wb")
                        if fh then fh:write(fb_files_hash); fh:close() end
                    end
                end

                -- 2b. Discover peers from local staging files
                local peers = {}
                local staging_dir = plugin.state_dir .. "cloud_staging/"
                require("util").makePath(staging_dir)
                local lfs = require("libs/libkoreader-lfs")
                for f in lfs.dir(staging_dir) do
                    local fh = io.open(staging_dir .. f, "rb")
                    if fh then
                        local content = fh:read("*a"); fh:close()
                        if content then
                            local ok_d, data = pcall(cjson.decode, content)
                            -- type(data) == "table" is required, not just
                            -- truthy: a stray non-envelope file in this
                            -- directory (e.g. .manifest_cache, a plain hash
                            -- string) can decode successfully to a bare
                            -- JSON number/string/boolean -- truthy in Lua,
                            -- but indexing .entries on it raises "attempt
                            -- to index a number/string/boolean value",
                            -- which pcall above does NOT catch (decode
                            -- itself succeeded; the error is in the
                            -- .entries access right here).
                            if ok_d and type(data) == "table" and data.entries then
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
                            if ok_d and type(data) == "table" then remote_manifest = data end
                        end
                    end)
                    if remote_manifest and remote_manifest.files and my_manifest and my_manifest.files then
                        local peer_keys = {}
                        for k in pairs(remote_manifest.files) do table.insert(peer_keys, k) end
                        table.sort(peer_keys)
                        local peer_h = sha2.md5; local peer_ctx = peer_h()
                        for _, k in ipairs(peer_keys) do peer_ctx(k); peer_ctx(remote_manifest.files[k]) end
                        local peer_hash = peer_ctx()
                        -- KNOWN LIMITATION (deliberately not fixed -- traced,
                        -- not overlooked): this cache is a SINGLE value, so
                        -- with 2+ peers each iteration's write below
                        -- overwrites the previous peer's contribution --
                        -- only the peer that sorts LAST (peer_ids is
                        -- alphabetical) ever gets a cache hit on the NEXT
                        -- run; every other peer redundantly re-runs the
                        -- local diff loop even when nothing changed for it.
                        -- Left as-is because: (1) zero extra network calls
                        -- either way -- downloadManifest above ALWAYS runs
                        -- per peer regardless of this cache; only the
                        -- local, pure-Lua per-book comparison is what gets
                        -- skipped or not. (2) can NEVER produce a WRONG
                        -- result -- the diff loop always reads THIS run's
                        -- freshly-downloaded remote/my_manifest files,
                        -- never cached data, so a redundant run just
                        -- re-derives the same correct (usually empty)
                        -- delta, and a correct skip only fires when the
                        -- peer's hash is genuinely unchanged. A real fix
                        -- needs a cache-format redesign (single value ->
                        -- per-device map) in a function with zero test
                        -- coverage, for a saving bounded by "iterate a
                        -- handful of book_id strings once" -- not worth
                        -- the regression risk. If revisiting: this is the
                        -- ONLY thing wrong here -- upload-skip, download
                        -- counts, and correctness are all unaffected.
                        do local fh = io.open(fb_cache_path, "wb")
                            if fh then fh:write(fb_files_hash .. "|" .. peer_hash); fh:close() end
                        end
                        if not (fb_skip_upload and fb_cached_peer_hash == peer_hash) then
                            -- Deterministic order: matches every other
                            -- pairs()-then-iterate spot in this file; keeps
                            -- "Downloading i/N..." numbering (and which
                            -- book that is) reproducible across runs
                            -- instead of depending on Lua's unordered
                            -- table iteration.
                            local remote_book_ids = {}
                            for book_id in pairs(remote_manifest.files) do
                                remote_book_ids[#remote_book_ids + 1] = book_id
                            end
                            table.sort(remote_book_ids)
                            for _, book_id in ipairs(remote_book_ids) do
                                local remote_hash = remote_manifest.files[book_id]
                                local my_hash = my_manifest.files[book_id]
                                if my_hash and my_hash ~= remote_hash then
                                    local path = listM.resolveBookPath(plugin, book_id)
                                    if path then table.insert(changed, {id = book_id, path = path}) end
                                elseif not my_hash and _isSafeBookId(book_id) then
                                    -- Cloud prefetch, fallback path (Constraint R):
                                    -- never known locally -- compare the LOCAL
                                    -- combined hash of whatever is already
                                    -- staged in cloud_staging/prefetch/ (empty
                                    -- string for each half never yet fetched)
                                    -- against the peer's single combined hash.
                                    -- No finer signal is available here than
                                    -- per-book (unlike Cloud Storage+'s
                                    -- per-kind size check) -- a change to
                                    -- either kind re-fetches both.
                                    local prefetch_dir = plugin.state_dir .. "cloud_staging/prefetch/"
                                    local function read_or_empty(path2)
                                        local fh = io.open(path2, "rb")
                                        if not fh then return "" end
                                        local c = fh:read("*a"); fh:close()
                                        return c or ""
                                    end
                                    local staged_progress = read_or_empty(
                                        prefetch_dir .. "syncery-progress-" .. book_id .. ".json")
                                    local staged_annotations = read_or_empty(
                                        prefetch_dir .. "syncery-annotations-" .. book_id .. ".json")
                                    local local_ctx = sha2.md5()
                                    local_ctx(staged_progress .. "\0" .. staged_annotations)
                                    local local_hash_combined = local_ctx()
                                    if local_hash_combined ~= remote_hash then
                                        _prefetchViaFallback(plugin, orch, book_id, "progress")
                                        _prefetchViaFallback(plugin, orch, book_id, "annotations")
                                    end
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
                else
                    info_fn(_("Up to date."))
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
                pl_cache_path = plugin.state_dir .. "cloud_staging/.manifest_cache"
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
                -- Record OUR hash now, independent of whether any peer is
                -- found below: the peer loop's own write (further down)
                -- already overwrites this with the fuller
                -- "our_hash|peer_hash" pair when a peer IS found, but with
                -- zero peers that write never runs -- without this line,
                -- pl_skip_upload would never see a cache hit and would
                -- re-upload the SAME unchanged manifest on every single
                -- sync_all call, indefinitely, until a peer eventually
                -- appears.
                do local fh = io.open(pl_cache_path, "wb")
                    if fh then fh:write(pl_files_hash); fh:close() end
                end
            end

--- BUGFIX:
--- WebDav.listFolder's own hasProvider filter
--- (plugins/cloudstorage.koplugin/providers/webdav.lua) silently drops any
--- entry with no registered DocumentRegistry provider unless
--- G_reader_settings "show_unsupported" is true. ".txt" (manifest files)
--- already has a registered provider, so that discovery path was never
-- (See _listFolderShowingUnsupported near the other module-level helpers.)

            -- 2b. List cloud directory for all manifest files
            local ok_list, entries = _listFolderShowingUnsupported(
                G_reader_settings, provider, server.url, true)
            if not ok_list or not entries then
                return
            end

            -- 2b-prefetch. Remote-only books (never opened on this device) --
            -- see docs/CLOUD_PREFETCH_DESIGN.md. Reuses THIS SAME `entries`
            -- listing (Constraint O/Q) -- no second network round-trip.
            -- Constraint V: staged under prefetch/, never the flat top
            -- level, so generateManifest's walk (2a, above) never sees
            -- these and its per-sync_all cost stays independent of
            -- prefetch volume.
            --
            -- Trapper feedback: the known-book push/pull phases above
            -- already report progress via info_fn -- prefetch had none,
            -- leaving the user staring at a stuck "Checking..." message
            -- (or nothing) for however long a peer's whole library takes
            -- to discover and download. Same info_fn, same pattern.
            do
                local by_book = _groupRemoteEntries(entries)
                local candidate_ids = {}
                for book_id, kinds in pairs(by_book) do
                    if not (my_manifest and my_manifest.files
                            and my_manifest.files[book_id]) then
                        table.insert(candidate_ids, book_id)
                    end
                end
                if #candidate_ids > 0 then
                    info_fn(string.format(
                        _("Checking %d never-opened book(s) for new data..."),
                        #candidate_ids))
                end
                for i, book_id in ipairs(candidate_ids) do
                    local kinds = by_book[book_id]
                    for kind, entry in pairs(kinds) do
                        local staging_path = plugin.state_dir
                            .. "cloud_staging/prefetch/syncery-" .. kind
                            .. "-" .. book_id .. ".json"
                        local staged_size = (function()
                            local lfs = Util.get_lfs()
                            return lfs and lfs.attributes(staging_path, "size")
                        end)()
                        -- Constraint N: nil-safe comparison -- either
                        -- side may be nil (never staged yet, or the
                        -- listing entry lacks a size for some reason).
                        if (not staged_size)
                                or (staged_size and staged_size ~= entry.filesize) then
                            info_fn(string.format(
                                _("Prefetching book %d/%d (%s)..."),
                                i, #candidate_ids, kind))
                            local ok_dl, err_dl = _downloadAndValidate(
                                plugin, provider, server, book_id, kind)
                            if not ok_dl then
                                logger.warn("Syncery: prefetch download failed for",
                                    book_id, kind, err_dl)
                            end
                        end
                    end
                end
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
                    -- KNOWN LIMITATION (deliberately not fixed -- traced,
                    -- not overlooked): this cache is a SINGLE value, so
                    -- with 2+ peers each iteration's write below overwrites
                    -- the previous peer's contribution -- only the peer
                    -- that sorts LAST (peer_ids is alphabetical) ever gets
                    -- a cache hit on the NEXT run; every other peer
                    -- redundantly re-runs the local diff loop even when
                    -- nothing changed for it. Left as-is because: (1) zero
                    -- extra network calls either way -- downloadManifest
                    -- above ALWAYS runs per peer regardless of this cache;
                    -- only the local, pure-Lua per-book comparison is what
                    -- gets skipped or not. (2) can NEVER produce a WRONG
                    -- result -- the diff loop always reads THIS run's
                    -- freshly-downloaded remote/my_manifest files, never
                    -- cached data, so a redundant run just re-derives the
                    -- same correct (usually empty) delta, and a correct
                    -- skip only fires when the peer's hash is genuinely
                    -- unchanged. A real fix needs a cache-format redesign
                    -- (single value -> per-device map) in a function with
                    -- zero test coverage, for a saving bounded by "iterate
                    -- a handful of book_id strings once" -- not worth the
                    -- regression risk. If revisiting: this is the ONLY
                    -- thing wrong here -- upload-skip, download counts,
                    -- and correctness are all unaffected.
                    do local fh = io.open(pl_cache_path, "wb")
                        if fh then fh:write(pl_files_hash .. "|" .. peer_hash); fh:close() end
                    end
                    if not (pl_skip_upload and pl_cached_peer_hash == peer_hash) then
                        -- Deterministic order: matches every other
                        -- pairs()-then-iterate spot in this file; keeps
                        -- "Downloading i/N..." numbering (and which book
                        -- that is) reproducible across runs instead of
                        -- depending on Lua's unordered table iteration.
                        local remote_book_ids = {}
                        for book_id in pairs(remote.files) do
                            remote_book_ids[#remote_book_ids + 1] = book_id
                        end
                        table.sort(remote_book_ids)
                        for _, book_id in ipairs(remote_book_ids) do
                            local remote_hash = remote.files[book_id]
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
            else
                info_fn(_("Up to date."))
            end

            Settings.set_last_sync_all_ts(os.time())
            end)   -- close body_ok pcall

            -- Always close whatever InfoMessage was last shown, regardless
            -- of which branch/early-return path was taken above, or
            -- whether it errored.
            Trapper:reset()
            if not body_ok then
                logger.warn("Syncery: sync_all inner error:", tostring(body_err))
            end
        end)
    end)

    plugin._sync_all_in_progress = false

    if not ok then
        logger.warn("Syncery: sync_all error:", tostring(err))
    end
end


return PluginSync
