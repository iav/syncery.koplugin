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
-- `plugin:getCurrentState`, the cloud status fields …).  Making them
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
local I18n          = require("syncery_i18n")
local StateStore    = require("syncery_ann/state_store")

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
    if not state or not plugin:_isFileTypeSynced(state.file) then return end

    -- Gate on CLOUD reachability (real internet + a bounded probe to the
    -- configured server), not the link-only `_isNetworkOnline`: KOReader runs
    -- the WebDAV/Dropbox transfer synchronously on the UI thread, so an
    -- enabled-but-unreachable cloud would freeze the UI.  Unreachable → defer
    -- via the cloud-scoped backoff (which re-probes reachability on retry).
    if not plugin:_isCloudReachable() then
        plugin._cloud_wifi_backoff:attempt{
            label = "cloud upload",
            run   = function() PluginSync.do_cloud_upload(plugin, state) end,
        }
        return
    end

    local entries = PluginSync._build_cloud_entries(plugin, state)
    if #entries == 0 then return end

    plugin._transport:push_cloud_files(state.file, entries,
        plugin.ui and plugin.ui.doc_settings)

    -- Record the dispatch time for the upload-debounce window.  Sync
    -- status itself is owned by the orchestrator and read via
    -- `_transport:get_status()`; this module no longer tracks a
    -- per-push ok flag.
    plugin.cloud_last_upload_at = os.time()
end


-- ----------------------------------------------------------------------------
-- _build_cloud_entries — read the staged progress/annotations off disk into the
-- { kind, content } list push_cloud_files expects.  Extracted so both the
-- synchronous do_cloud_upload and the forked do_cloud_upload_bg build the
-- IDENTICAL payload from the same on-disk bytes.
--
-- The cloud transport reads each file's content from disk inside its push(); we
-- build the entries list and hand it to the bridge, which derives book_id
-- internally.  Reading the content here means a single read per save.
-- ----------------------------------------------------------------------------
function PluginSync._build_cloud_entries(plugin, state)
    local entries = {}
    local p_path = ProgressPaths.shared_progress_path(state.file)
    local a_path = AnnPaths.shared_annotations_path(state.file)

    if p_path then
        local f = io.open(p_path, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                table.insert(entries, { kind = "progress", content = content })
            end
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
    return entries
end


-- ----------------------------------------------------------------------------
-- do_cloud_upload_bg — the same cloud push as do_cloud_upload, but the whole
-- SyncService cycle (download + 3-way merge + upload) runs in a FORKED
-- SUBPROCESS so the caller (close/quit teardown) is not frozen by it.
--
-- The child writes the merged canonical files to the shared filesystem; the
-- parent stays responsive and a poller reaps the child.  Conflict-safety is
-- preserved (full merge, just off the UI thread).  is_silent=true is already
-- hard-wired into the cloud adapter's SyncService.sync call, so the child
-- raises no toasts (it must touch net+disk only).
--
-- Returns true if the push was backgrounded, false if it could not be (fork
-- unavailable, cloud unreachable, nothing to push) — the caller then runs the
-- synchronous do_cloud_upload fallback.
-- ----------------------------------------------------------------------------
function PluginSync.do_cloud_upload_bg(plugin, state)
    local function dbg(msg)
        if logger and logger.dbg then logger.dbg("Syncery: bg-close-flush: " .. msg) end
    end
    if not plugin.use_cloud then dbg("decline: use_cloud off"); return false end
    if not plugin._transport then dbg("decline: no transport"); return false end
    if not Settings.is_cloud_configured() then dbg("decline: cloud not configured"); return false end
    state = state or plugin:getCurrentState()
    if not state or not plugin:_isFileTypeSynced(state.file) then
        dbg("decline: no state / file not synced"); return false
    end

    -- Reachability gate mirrors do_cloud_upload: if the cloud is unreachable
    -- there is nothing a fork can do, so decline and let the sync path take its
    -- normal (backoff) route.
    if not plugin:_isCloudReachable() then dbg("decline: cloud unreachable"); return false end

    -- Fork ONLY when the active provider transfers synchronously (the built-in
    -- syncservice): the whole download/merge/upload cycle then runs inside the
    -- child before it exits.  The "Cloud storage+" provider instead DEFERS its
    -- transfer via UIManager:nextTick — a forked child exits before any tick
    -- can run, so the push would be silently LOST while we report success
    -- (codex).  Decline so those setups keep the working foreground path.
    if not plugin:_isCloudPushSynchronous() then
        dbg("decline: async cloud provider (a fork would drop the transfer)")
        return false
    end

    local entries = PluginSync._build_cloud_entries(plugin, state)
    if #entries == 0 then dbg("decline: no entries to push"); return false end

    -- Capture what the child needs BEFORE the fork; the child gets a
    -- copy-on-write snapshot and must not reach back into live parent state.
    local transport    = plugin._transport
    local file         = state.file
    local doc_settings = plugin.ui and plugin.ui.doc_settings

    local BgFlush = require("syncery_transports/bg_flush")

    -- Overlap guard (codex): a second flush for the SAME book while an earlier
    -- child is still merging/uploading would overwrite the fixed staging paths
    -- (cloud_staging/…) under it — and a synchronous fallback would race it the
    -- same way.  Report the push as handled instead: the fresh state is already
    -- on disk and goes out with the next open/sync cycle.
    if BgFlush.in_flight(file) then
        dbg("decline: a background push for this book is still running — "
            .. "skipping; the new state stays on disk for the next sync")
        return true
    end

    local child_task = function()
        -- CHILD PROCESS: network + filesystem ONLY.  push_cloud_files ->
        -- orchestrator -> SyncService.sync (is_silent=true).  Never UIManager /
        -- logger / e-ink here.  The merged canonical is written to the shared FS.
        -- Entries are re-read HERE, at execution time, not at fork-decision
        -- time: the canonical files may have moved between the close that
        -- scheduled this push and the moment the child runs (codex).
        local fresh = PluginSync._build_cloud_entries(plugin, state)
        if #fresh == 0 then return end
        transport:push_cloud_files(file, fresh, doc_settings)
    end

    dbg("forking cloud push (" .. #entries .. " entries)")
    local launched = BgFlush.run(child_task, nil, { logger = logger, key = file })
    dbg(launched and "FORKED — backgrounded" or "fork unavailable — caller falls back to sync")
    if launched then
        plugin.cloud_last_upload_at = os.time()
    end
    return launched
end


return PluginSync
