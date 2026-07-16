-- =============================================================================
-- spec/transport_plugin_sync_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/plugin_sync.lua — the plugin-facing
-- transport glue relocated out of main.lua in Phase 9.3.
--
-- The four functions are guard-heavy: most of the surface is "bail
-- early when a toggle is off / unconfigured / offline".  These tests
-- exercise those gates plus the happy-path dispatch onto a fake
-- transport.  Every dependency (Settings, the transport, the wifi
-- backoff, network probe) is stubbed — no KOReader code, no network.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_plugin_sync_spec_" .. tostring(os.time()))


-- ---------------------------------------------------------------------------
-- Stub syncery_settings BEFORE requiring plugin_sync.  The defaults
-- below describe a fully-configured cloud setup; individual tests flip
-- a flag to exercise the unconfigured paths.
-- ---------------------------------------------------------------------------

local settings_state = {
    cloud_configured  = true,
}

package.loaded["syncery_settings"] = {
    is_cloud_configured   = function() return settings_state.cloud_configured  end,
}


local PluginSync = require("syncery_transports/plugin_sync")


-- ---------------------------------------------------------------------------
-- Fake plugin builder.  Records every transport call and timer schedule
-- so tests can assert on them.  `opts` overrides the defaults.
-- ---------------------------------------------------------------------------

local function make_plugin(opts)
    opts = opts or {}
    local p = {
        use_cloud    = opts.use_cloud    ~= false,
        -- Fix 4's content-hash push cache
        -- reads/writes under plugin.state_dir -- this fixture never set
        -- it before that fix existed, since nothing here needed it.
        state_dir    = opts.state_dir or (h.test_root .. "/"),
        sync_progress = opts.sync_progress ~= false,
        sync_annotations     = opts.sync_annotations,
        sync_metadata        = opts.sync_metadata,
        sync_render_settings = opts.sync_render_settings,
        destroyed    = opts.destroyed or false,
        is_saving    = opts.is_saving or false,
        sync_state   = opts.sync_state or "idle",
        _active_sync_box = opts.active_sync_box,
        device_label = "TestDevice",
        cloud_upload_delay = 60,
        ui = opts.ui,
        _online = opts.online ~= false,
        _cloud_online = opts.cloud_online ~= false,

        -- recorders
        _calls    = {},
        _schedules = {},
    }

    -- A transport that records each push.
    p._transport = opts.no_transport and nil or {
        push_cloud_files = function(_, file, entries)
            table.insert(p._calls, { m = "push_cloud_files", file = file, entries = entries })
        end,
    }

    function p:_isNetworkOnline() return self._online end
    function p:_isCloudReachable() return self._cloud_online end
    function p:getCurrentState()  return opts.state end
    function p:_isFileTypeSynced() return opts.file_type_synced ~= false end

    -- Fix 4's push-content cache persists on disk under state_dir and
    -- would otherwise leak across this file's separate do{} blocks (they
    -- share h.test_root) -- start each one fresh.
    require("syncery_transports/plugin_sync")._write_push_cache(p, {})
    function p:_promptJump(args)
        table.insert(self._calls, { m = "_promptJump", args = args })
    end
    function p:_schedule(slot, delay, fn)
        table.insert(self._schedules, { slot = slot, delay = delay, fn = fn })
    end

    -- wifi backoff recorders (link-scoped + cloud-scoped)
    p._wifi_backoff = {
        attempt = function(_, a)
            table.insert(p._calls, { m = "wifi_attempt", label = a.label, run = a.run })
        end,
    }
    p._cloud_wifi_backoff = {
        attempt = function(_, a)
            table.insert(p._calls, { m = "cloud_wifi_attempt", label = a.label, run = a.run })
        end,
    }

    return p
end

local function called(p, method)
    for _, c in ipairs(p._calls) do
        if c.m == method then return c end
    end
    return nil
end


-- ===========================================================================
-- schedule_cloud_upload
-- ===========================================================================

-- use_cloud off → nothing scheduled.
do
    local p = make_plugin{ use_cloud = false }
    PluginSync.schedule_cloud_upload(p, { file = "/b.epub" })
    h.assert_equal(#p._schedules, 0, "cloud schedule: use_cloud off → nothing scheduled")
end

-- nil state → nothing scheduled.
do
    local p = make_plugin{}
    PluginSync.schedule_cloud_upload(p, nil)
    h.assert_equal(#p._schedules, 0, "cloud schedule: nil state → nothing scheduled")
end

-- Configured + state → schedules on the _cloud_upload_action slot.
do
    local p = make_plugin{}
    PluginSync.schedule_cloud_upload(p, { file = "/b.epub" })
    h.assert_equal(#p._schedules, 1, "cloud schedule: one timer scheduled")
    h.assert_equal(p._schedules[1].slot, "_cloud_upload_action",
        "cloud schedule: uses the _cloud_upload_action slot")
    h.assert_equal(p._schedules[1].delay, 60,
        "cloud schedule: uses cloud_upload_delay")
end

-- Unconfigured → nothing scheduled.
do
    settings_state.cloud_configured = false
    local p = make_plugin{}
    PluginSync.schedule_cloud_upload(p, { file = "/b.epub" })
    h.assert_equal(#p._schedules, 0, "cloud schedule: unconfigured → nothing scheduled")
    settings_state.cloud_configured = true
end


-- ===========================================================================
-- do_cloud_upload
-- ===========================================================================

-- use_cloud off → no-op.
do
    local p = make_plugin{ use_cloud = false }
    PluginSync.do_cloud_upload(p, { file = "/b.epub" })
    h.assert_nil(called(p, "push_cloud_files"), "cloud upload: use_cloud off → no push")
end

-- No transport → no-op.
do
    local p = make_plugin{ no_transport = true }
    PluginSync.do_cloud_upload(p, { file = "/b.epub" })
    -- no transport object to record onto; just assert it didn't crash
    h.assert_true(true, "cloud upload: missing transport → safe no-op")
end

-- Unconfigured → no upload dispatched.
do
    settings_state.cloud_configured = false
    local p = make_plugin{}
    PluginSync.do_cloud_upload(p, { file = "/b.epub" })
    -- The dead cloud_last_upload_ok flag was removed in Phase 12.1;
    -- the observable contract is simply that nothing is pushed.
    h.assert_nil(called(p, "push_cloud_files"),
        "cloud upload: unconfigured → no upload dispatched")
    h.assert_nil(p.cloud_last_upload_ok,
        "cloud upload: unconfigured → dead cloud_last_upload_ok flag not set")
    settings_state.cloud_configured = true
end

-- Cloud unreachable (link up but no route, or the server down) → defer via the
-- cloud-scoped backoff, do not push.  This pins the wiring: do_cloud_upload
-- must gate on _isCloudReachable + _cloud_wifi_backoff (real reachability), NOT
-- the link-only _isNetworkOnline + _wifi_backoff that Syncthing (localhost)
-- uses.  `online` stays true here, so ONLY the cloud-reachability gate can defer.
do
    local p = make_plugin{ cloud_online = false }
    PluginSync.do_cloud_upload(p, { file = "/b.epub" })
    local c = called(p, "cloud_wifi_attempt")
    h.assert_true(c ~= nil,
        "cloud upload: unreachable cloud → cloud-scoped backoff scheduled")
    h.assert_equal(c.label, "cloud upload", "cloud upload: backoff labelled")
    h.assert_nil(called(p, "push_cloud_files"),
        "cloud upload: unreachable cloud → no push")
    h.assert_nil(called(p, "wifi_attempt"),
        "cloud upload: unreachable cloud → uses the cloud backoff, not the link one")
end

-- Online + configured, both files absent on disk, AND every sync master OFF
-- → nothing to stage → empty entries → no push.  (With a master ON the
-- fresh-device bootstrap stages an empty envelope so the PULL runs -- see the
-- two bootstrap cases below.)
do
    local p = make_plugin{ sync_progress = false }
    PluginSync.do_cloud_upload(p, { file = "/no/such/book.epub" })
    h.assert_nil(called(p, "push_cloud_files"),
        "cloud upload: no files on disk + all sync OFF → empty entries → no push")
end

-- Fresh-device PULL bootstrap: no local annotations file but the annotations
-- master is ON → stage an in-memory empty envelope so the bidirectional sync
-- RUNS and DOWNLOADS a peer's annotations (then on_reconciled fires the Reload
-- toast).  Without it a never-annotated device never pulls (cloud-only;
-- Syncthing replicates the shared file at FS level).  No file is written.
do
    local p = make_plugin{ sync_annotations = true }
    PluginSync.do_cloud_upload(p, { file = "/no/such/book.epub" })
    local c = called(p, "push_cloud_files")
    h.assert_true(c ~= nil,
        "cloud upload: no ann file + annotations ON → push happens to pull remote")
    local has_ann = false
    for _, e in ipairs((c and c.entries) or {}) do
        if e.kind == "annotations" then has_ann = true end
    end
    h.assert_true(has_ann,
        "cloud upload: an in-memory empty annotations envelope is staged so the pull runs")
end

-- Fresh-device PULL bootstrap, PROGRESS side: no local progress file but the
-- progress master is ON → stage an in-memory empty progress envelope so the
-- bidirectional sync RUNS and DOWNLOADS a peer's reading position at OPEN
-- (then on_reconciled drives checkRemote / the jump).  Without it the peer's
-- position arrives only on the next debounced upload after our own autosave,
-- up to cloud_upload_delay later -- too late for the open-moment jump.
do
    local p = make_plugin{ sync_progress = true }
    PluginSync.do_cloud_upload(p, { file = "/no/such/book.epub" })
    local c = called(p, "push_cloud_files")
    h.assert_true(c ~= nil,
        "cloud upload: no progress file + progress ON → push happens to pull remote position")
    local has_progress = false
    for _, e in ipairs((c and c.entries) or {}) do
        if e.kind == "progress" then has_progress = true end
    end
    h.assert_true(has_progress,
        "cloud upload: an in-memory empty progress envelope is staged so the position pull runs")
end

-- BUGFIX: the toggle checks above used to apply ONLY to
-- the bootstrap-empty-envelope branch. If REAL content already existed
-- on disk (e.g. from before the user turned a toggle off), it was read
-- and pushed unconditionally, ignoring the toggle entirely. These two
-- tests use a REAL book file with REAL existing canonical content --
-- unlike the bootstrap tests above, which deliberately use a
-- non-existent path to exercise the empty-envelope branch.
local ProgressPaths = require("syncery_progress/paths")
local AnnPaths       = require("syncery_ann/paths")

do
    local book = h.test_root .. "/existing_progress.epub"
    local p_path = ProgressPaths.shared_progress_path(book)
    require("util").makePath(p_path:match("^(.*/)"))
    local f = io.open(p_path, "wb")
    f:write('{"entries":{"dev1":{"percent":0.5}}}'); f:close()

    local p = make_plugin{ sync_progress = false }
    PluginSync.do_cloud_upload(p, { file = book })
    local c = called(p, "push_cloud_files")
    local has_progress = false
    for _, e in ipairs((c and c.entries) or {}) do
        if e.kind == "progress" then has_progress = true end
    end
    h.assert_false(has_progress,
        "cloud upload: EXISTING progress content on disk is NOT pushed when sync_progress=false")
end

do
    local book = h.test_root .. "/existing_annotations.epub"
    local a_path = AnnPaths.shared_annotations_path(book)
    require("util").makePath(a_path:match("^(.*/)"))
    local f = io.open(a_path, "wb")
    f:write('{"annotations":{"k":{"text":"existing highlight"}}}'); f:close()

    local p = make_plugin{ sync_progress = false, sync_annotations = false,
        sync_metadata = false, sync_render_settings = false }
    PluginSync.do_cloud_upload(p, { file = book })
    local c = called(p, "push_cloud_files")
    local has_ann = false
    for _, e in ipairs((c and c.entries) or {}) do
        if e.kind == "annotations" then has_ann = true end
    end
    h.assert_false(has_ann,
        "cloud upload: EXISTING annotations content on disk is NOT pushed "
        .. "when all three annotation-covering toggles are off")
end


-- ---------------------------------------------------------------------------
-- Fix 4: content-hash push cache. Real, EXISTING content that is
-- byte-identical to what was already dispatched last time must be
-- skipped -- but only when it genuinely repeats; a real change, or a
-- different book entirely, must still push. Deliberately does NOT touch
-- the bootstrap-empty-envelope tests above (Constraint: that path is
-- explicitly excluded from this cache -- see the code comment on why).
-- ---------------------------------------------------------------------------

do
    local book = h.test_root .. "/fix4_repeat.epub"
    local p_path = ProgressPaths.shared_progress_path(book)
    require("util").makePath(p_path:match("^(.*/)"))
    local function write(content)
        local f = io.open(p_path, "wb"); f:write(content); f:close()
    end

    -- skip_if_unchanged = true: matches pushOpenedBooks' own call shape,
    -- the ONLY caller Fix 4's cache is opt-in for (see the code comment
    -- on use_skip_cache -- every other call site must NOT set this, so
    -- it always dispatches instead).
    write('{"entries":{"dev1":{"percent":0.10}}}')
    local p = make_plugin{}
    PluginSync.do_cloud_upload(p, { file = book, skip_if_unchanged = true })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "fix4: first push with real content dispatches")

    -- Second call, SAME content, SAME book -- must be skipped entirely
    -- (zero push_cloud_files calls this time).
    p._calls = {}
    PluginSync.do_cloud_upload(p, { file = book, skip_if_unchanged = true })
    h.assert_true(called(p, "push_cloud_files") == nil,
        "fix4: identical content on a second call is skipped, not re-pushed")

    -- Content genuinely changes -- must push again.
    write('{"entries":{"dev1":{"percent":0.55}}}')
    p._calls = {}
    PluginSync.do_cloud_upload(p, { file = book, skip_if_unchanged = true })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "fix4: genuinely changed content still pushes, cache does not stick forever")
end

do
    -- A DIFFERENT book with the exact same content as another book's
    -- cached entry must NOT be affected by that other book's cache --
    -- the cache is keyed per book_file, not globally by content hash.
    local book_a = h.test_root .. "/fix4_book_a.epub"
    local book_b = h.test_root .. "/fix4_book_b.epub"
    local pa = ProgressPaths.shared_progress_path(book_a)
    local pb = ProgressPaths.shared_progress_path(book_b)
    require("util").makePath(pa:match("^(.*/)"))
    require("util").makePath(pb:match("^(.*/)"))
    local same_content = '{"entries":{"dev1":{"percent":0.20}}}'
    do local f = io.open(pa, "wb"); f:write(same_content); f:close() end
    do local f = io.open(pb, "wb"); f:write(same_content); f:close() end

    local p = make_plugin{}
    PluginSync.do_cloud_upload(p, { file = book_a, skip_if_unchanged = true })
    p._calls = {}
    PluginSync.do_cloud_upload(p, { file = book_b, skip_if_unchanged = true })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "fix4: a DIFFERENT book with identical content to another book's "
        .. "cache entry still pushes -- the cache is per-book, not global")
end


-- ---------------------------------------------------------------------------
-- Fix 4 refinement: the skip-cache must NEVER apply when the caller
-- passes force_sync = true (state.force_sync). sync_changed (Phase 2)
-- calls do_cloud_upload with this set because the manifest comparison
-- ALREADY determined this book_id's hash differs from the peer's -- the
-- whole point of that call is to run the bidirectional merge and pull
-- the peer's side in, regardless of whether OUR OWN local content has
-- changed since our last push. Skip-caching that call would silently
-- skip the pull too. Confirmed originally via the two-device
-- investigation harness, where NOT gating this caused real, silent data
-- loss (a device's own round-trip sync stopped pulling a peer's
-- contribution) before this force_sync bypass was added.
-- ---------------------------------------------------------------------------

do
    local book = h.test_root .. "/fix4_force_sync.epub"
    local p_path = ProgressPaths.shared_progress_path(book)
    require("util").makePath(p_path:match("^(.*/)"))
    local content = '{"entries":{"dev1":{"percent":0.30}}}'
    local f = io.open(p_path, "wb"); f:write(content); f:close()

    local p = make_plugin{}
    -- First call opts IN (skip_if_unchanged = true, matching
    -- pushOpenedBooks' shape) so it genuinely populates a cache entry
    -- that WOULD cause a hit on unchanged content next time.
    PluginSync.do_cloud_upload(p, { file = book, skip_if_unchanged = true })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "fix4/force_sync: first call (skip_if_unchanged) dispatches normally")

    -- Second call, SAME content, but force_sync = true (matching
    -- sync_changed's call shape): must STILL dispatch, must NOT be
    -- silently skipped by the cache, even though the first call above
    -- left a matching cache entry behind.
    p._calls = {}
    PluginSync.do_cloud_upload(p, { file = book, force_sync = true })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "fix4/force_sync: force_sync=true bypasses the skip-cache even "
        .. "with byte-identical content, so a manifest-triggered pull is "
        .. "never silently dropped")
end

do
    -- The REVERSE ordering: force_sync=true FIRST must NEVER populate
    -- the push cache (the code deliberately forces push_cache = {} for
    -- force_sync calls and skips the write-back entirely -- see the
    -- comment above use_skip_cache's write-back block: writing from an
    -- empty forced table would silently WIPE every OTHER book's cached
    -- entry). So a LATER call that opts into skip_if_unchanged on the
    -- same (unchanged) content must find NO cache entry and correctly
    -- DISPATCH, not skip -- proving force_sync's dispatch left the cache
    -- untouched rather than writing something that could interfere.
    local book = h.test_root .. "/fix4_force_sync_order.epub"
    local p_path = ProgressPaths.shared_progress_path(book)
    require("util").makePath(p_path:match("^(.*/)"))
    local content = '{"entries":{"dev1":{"percent":0.40}}}'
    local f = io.open(p_path, "wb"); f:write(content); f:close()

    local p = make_plugin{}
    PluginSync.do_cloud_upload(p, { file = book, force_sync = true })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "fix4/force_sync: a force_sync=true call dispatches")

    p._calls = {}
    PluginSync.do_cloud_upload(p, { file = book, skip_if_unchanged = true })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "fix4/force_sync: force_sync's own dispatch left the cache "
        .. "untouched -- a later skip_if_unchanged call on the same "
        .. "content still dispatches (finds no entry), proving force_sync "
        .. "never wrote one")
end


-- ---------------------------------------------------------------------------
-- BUGFIX: a PLAIN call -- no skip_if_unchanged,
-- no force_sync, matching the open-moment pull / resume pull / autosave
-- debounce call sites' shape -- must ALWAYS dispatch, even with byte-
-- identical content, because push and pull are the SAME bidirectional
-- operation here (see the use_skip_cache comment): skipping the dispatch
-- because OUR OWN content looks unchanged also means never asking the
-- server whether a PEER pushed something new. Confirmed via two real-
-- device manifestations traced to this exact gap: device B never saw
-- device A's new annotation, and device A missed a genuine recency-based
-- jump-prompt window for device B's progress update, both because the
-- kind in question looked cache-unchanged on a plain call and the whole
-- bidirectional check was skipped. Fix 4's skip-cache must now be OPT-IN
-- (skip_if_unchanged = true), so a plain call never consults it at all.
-- ---------------------------------------------------------------------------

do
    local book = h.test_root .. "/fix4_plain_call_always_dispatches.epub"
    local p_path = ProgressPaths.shared_progress_path(book)
    require("util").makePath(p_path:match("^(.*/)"))
    local content = '{"entries":{"dev1":{"percent":0.10}}}'
    local f = io.open(p_path, "wb"); f:write(content); f:close()

    local p = make_plugin{}
    PluginSync.do_cloud_upload(p, { file = book })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "plain call: first dispatch with real content dispatches")

    -- Second plain call, SAME content, SAME book, no flags at all --
    -- must STILL dispatch (never skipped), unlike the skip_if_unchanged
    -- variant above. This is the exact shape of the scheduled open-
    -- moment pull / resume pull / autosave debounce -- calls that exist
    -- specifically to keep checking the server for a peer's update.
    p._calls = {}
    PluginSync.do_cloud_upload(p, { file = book })
    h.assert_true(called(p, "push_cloud_files") ~= nil,
        "plain call: identical content on a second plain call still "
        .. "dispatches -- Fix 4's cache is opt-in and a plain call never "
        .. "consults it, so the bidirectional check (and therefore any "
        .. "peer update discovery) is never silently skipped")
end


h.teardown()
