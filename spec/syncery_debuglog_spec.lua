-- =============================================================================
-- spec/syncery_debuglog_spec.lua
-- =============================================================================
--
-- Coverage for syncery_debuglog.lua -- the permanent, menu-toggled verbose
-- sync logging feature (Advanced > "Verbose sync logging", default OFF).
--
-- Three things this spec proves:
--   1. Disabled (the default): _G.SYNCERY_DEBUG_LOG.* calls are silent --
--      no debug.txt, no writes.
--   2. Enabled: calls actually write to debug.txt, and the file rotates
--      (bounded growth) rather than growing forever.
--   3. The MtimeGate.run monkey-patch ALWAYS calls the original function,
--      regardless of the enabled flag -- the instrumentation must never
--      change real behaviour, only whether it is observed.
--
-- =============================================================================

local h = require("spec.test_helpers")
local test_root = "/tmp/syncery_debuglog_spec_" .. tostring(os.time())
h.setup(test_root)

local DebugLog = require("syncery_debuglog")

local debug_path = test_root .. "/syncery/debug.txt"

local function read_debug_file()
    local f = io.open(debug_path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function line_count(content)
    if not content then return 0 end
    local n = 0
    for _ in content:gmatch("\n") do n = n + 1 end
    return n
end


-- ----------------------------------------------------------------------------
-- 1. Disabled by default: silent.
-- ----------------------------------------------------------------------------

do
    h.assert_false(DebugLog.is_enabled(), "debug logging is disabled by default")

    os.remove(debug_path)
    _G.SYNCERY_DEBUG_LOG.jump_target("/book.epub", { D1 = { percent = 0.5 } }, nil, nil, 0)
    _G.SYNCERY_DEBUG_LOG.reload_toast_shown("should not appear")
    _G.SYNCERY_DEBUG_LOG.session_end()

    h.assert_true(read_debug_file() == nil,
        "no debug.txt is created while disabled -- every _G.SYNCERY_DEBUG_LOG "
        .. "call is a cheap no-op (one upvalue read and a branch)")
end


-- ----------------------------------------------------------------------------
-- 2. Enabled: writes actually happen, both known events and unknown-field
--    safety (a call with the wrong arg count/type must never raise).
-- ----------------------------------------------------------------------------

do
    DebugLog.set_enabled(true)
    h.assert_true(DebugLog.is_enabled(), "set_enabled(true) takes effect immediately")

    os.remove(debug_path)
    _G.SYNCERY_DEBUG_LOG.jump_target("/book.epub", { D1 = { percent = 0.5 } },
        "D1", "D1", 12345)
    _G.SYNCERY_DEBUG_LOG.reload_toast_shown("1 new annotation from another device")

    local content = read_debug_file()
    h.assert_true(content ~= nil, "debug.txt is created once enabled and a call fires")
    if content then
        h.assert_true(content:find("jump_target", 1, true) ~= nil,
            "jump_target's event name appears in debug.txt")
        h.assert_true(content:find("reload_toast_shown", 1, true) ~= nil,
            "reload_toast_shown's event name appears in debug.txt")
        h.assert_true(content:find("Syncery%[DEBUG%]") ~= nil,
            "every line carries the grep-friendly Syncery[DEBUG] prefix")
    end
end


-- ----------------------------------------------------------------------------
-- 3. Rotation: writing well past the cap does not grow the file forever.
-- ----------------------------------------------------------------------------

do
    DebugLog.set_enabled(true)
    os.remove(debug_path)

    for _ = 1, 4000 do
        _G.SYNCERY_DEBUG_LOG.on_reconciled_fired()
    end

    local content = read_debug_file()
    h.assert_true(content ~= nil, "debug.txt exists after many writes")
    local n = line_count(content)
    -- Size-triggered, approximate cap (not an exact line-count guarantee --
    -- see syncery_debuglog.lua's own docstring): bounded growth is what
    -- matters here, not hitting exactly 1000.
    h.assert_true(n < 4000,
        "debug.txt rotated at least once -- 4000 writes did not all "
        .. "accumulate forever (got " .. tostring(n) .. " lines)")
    h.assert_true(n < 3000,
        "the rotated file stays in the right ballpark, not just barely "
        .. "under the raw write count (got " .. tostring(n) .. " lines)")
end


-- ----------------------------------------------------------------------------
-- 4. MtimeGate.run wrap: ALWAYS calls the original function and returns
--    its real result, regardless of the enabled flag -- the instrumentation
--    must never change real sync behaviour, only whether it is logged.
-- ----------------------------------------------------------------------------

do
    -- Self-contained: explicitly reset and re-require BOTH modules
    -- fresh, in the correct order, within this one test -- so this test
    -- verifies the ACTUAL wrapped behaviour (enabled-gated logging
    -- around a real original_run call) on a known-consistent pair of
    -- instances, rather than depending on whatever cross-spec-file
    -- module-caching state run_tests.lua's shared dofile process
    -- happens to have left behind (run_tests.lua dofile's every spec in
    -- ONE Lua process, so package.loaded persists across spec files;
    -- in real KOReader usage both modules load exactly once, in one
    -- session, so this reset is purely a test-isolation concern).
    package.loaded["syncery_ann/mtime_gate"] = nil
    package.loaded["syncery_debuglog"] = nil
    local FreshMtimeGate = require("syncery_ann/mtime_gate")
    h.assert_false(FreshMtimeGate._syncery_debug_wrapped == true,
        "sanity: a freshly re-required MtimeGate starts unwrapped")
    local FreshDebugLog = require("syncery_debuglog")
    h.assert_true(FreshMtimeGate._syncery_debug_wrapped == true,
        "requiring syncery_debuglog wraps THIS instance of MtimeGate.run")

    local calls = 0
    local function do_sync() calls = calls + 1 end

    FreshDebugLog.set_enabled(false)
    local new_cache, did_sync = FreshMtimeGate.run(100, 0, do_sync, function() return 100 end)
    h.assert_equal(calls, 1, "original_run's do_sync fires even while logging is disabled")
    h.assert_true(did_sync, "MtimeGate.run's real return value (did_sync) is unaffected")
    h.assert_equal(new_cache, 100, "MtimeGate.run's real return value (new_cache) is unaffected")

    FreshDebugLog.set_enabled(true)
    new_cache, did_sync = FreshMtimeGate.run(100, 100, do_sync, function() return 100 end)
    h.assert_equal(calls, 1, "unchanged mtime correctly skips do_sync while logging is enabled too")
    h.assert_false(did_sync, "MtimeGate.run's real skip decision is unaffected by logging state")

    -- Restore the globally-cached instances the rest of this spec (and
    -- any LATER spec in the same shared process) expects to find.
    DebugLog = require("syncery_debuglog")
end


-- ----------------------------------------------------------------------------
-- 5. Unknown/malformed calls never raise -- a disabled OR enabled debug
--    hook must never be able to crash the app it instruments.
-- ----------------------------------------------------------------------------

do
    DebugLog.set_enabled(true)
    local ok = pcall(function()
        _G.SYNCERY_DEBUG_LOG.jump_target()  -- no args at all
        _G.SYNCERY_DEBUG_LOG.render_field(nil, nil, nil, nil, nil, nil, nil)
    end)
    h.assert_true(ok, "calling known events with missing/nil args does not raise")

    DebugLog.set_enabled(false)
end


h.teardown()
