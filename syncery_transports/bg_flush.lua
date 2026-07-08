-- =============================================================================
-- syncery_transports/bg_flush.lua
-- =============================================================================
--
-- Run a self-contained flush task in a FORKED SUBPROCESS so the UI thread is
-- not frozen by KOReader's synchronous cloud sync.
--
-- WHY THIS EXISTS
--
-- A cloud push is `SyncService.sync` per file: download -> 3-way merge (writes
-- the canonical file to disk) -> upload, all synchronous on the single UI
-- thread (~15 s per file on slow hardware).  On close that stalls the whole UI
-- for the duration.  KOReader is single-threaded, so deferring the call to a
-- later tick does not help — it would just move the same blocking work to a
-- later moment.  The only way to get the work OFF the UI thread without giving
-- up the 3-way merge (i.e. without losing conflict-safety) is to fork: the
-- child does the network + merge and writes the merged canonical files to the
-- SHARED filesystem; the parent stays responsive and only reads the result
-- back off disk later.  Verified on-device (armv6 Kindle 3): fork + TLS + disk
-- write + reap all work, both from a bare luajit and from a live ReaderUI.
--
-- CONTRACT FOR `task` (runs IN THE CHILD)
--
-- The task closure runs in the forked child, which shares the parent's memory
-- copy-on-write and its open fds (screen, input, sockets).  It MUST:
--   * touch ONLY the network and the filesystem;
--   * NEVER touch UIManager / the e-ink screen / input / the logger — those
--     fds belong to the parent, and the child exits immediately after `task`
--     (see ffiutil.runInSubProcess).  Cloud pushes already pass is_silent=true
--     to SyncService.sync, so they raise no toasts.
-- Any value the task wants to hand back must go through the FILESYSTEM (the
-- canonical files it writes), not a return value — memory is not shared back.
--
-- COMPLETION
--
-- The parent polls `is_done(pid)` on the injected scheduler and calls
-- `on_done(ok)` once, when the child is reaped (ok=true) or a wall-clock guard
-- fires (ok=false; a stuck/overrunning child).  On e-ink the scheduler ticks
-- lazily while the device is idle, so completion is detected on the next UI
-- wake — that is fine: nothing is lost, the transport teardown that `on_done`
-- drives simply happens a little later.
--
-- TESTABILITY
--
-- Every external dependency is injectable (the orchestrator.lua pattern), so
-- unit tests drive the whole state machine with a fake fork/scheduler and no
-- real subprocess.  Missing deps default to the real KOReader ones via lazy,
-- defensive require so the module also loads in a bare test environment.
-- =============================================================================


local BgFlush = {}


-- PIDs whose poller gave up (guard fired) before the child was reaped.  Kept at
-- module scope, like ReaderThumbnail's pids_to_collect, so a later run() can
-- reap them and they don't linger as zombies across the wait window.
local _orphans = {}

-- Live children by caller-supplied key (e.g. the book file), so a second flush
-- for the SAME book can be declined while the first is still merging/uploading
-- — overlapping children share fixed staging paths (cloud_staging/…) and would
-- overwrite them under each other.
local _in_flight = {}


-- Resolve the fork/reap primitives + scheduler, honoring injected `deps` first
-- (tests) and falling back to KOReader's real modules.  Returns nil for any
-- piece that can't be resolved so run() can decide it cannot background.
local function resolve(deps)
    deps = deps or {}
    local fork      = deps.fork
    local is_done   = deps.is_done
    local scheduler = deps.scheduler
    if not fork or not is_done then
        local ok, ffiutil = pcall(require, "ffi/util")
        if ok and ffiutil then
            fork    = fork    or ffiutil.runInSubProcess
            is_done = is_done or ffiutil.isSubProcessDone
        end
    end
    if not scheduler then
        local ok, UIManager = pcall(require, "ui/uimanager")
        if ok then scheduler = UIManager end
    end
    return fork, is_done, scheduler, deps
end


-- Test seam: how many guard-parked pids are awaiting reap.  Not used in
-- production; lets unit tests observe the otherwise-internal orphan list.
function BgFlush._orphan_count() return #_orphans end


-- Reap any orphaned children left by an earlier guard-fired run.  Non-blocking:
-- isSubProcessDone(pid) reaps if finished, leaves it otherwise.  Also drops the
-- in-flight key of any reaped pid so the book becomes flushable again.
function BgFlush.sweep_orphans(is_done)
    if not is_done or #_orphans == 0 then return end
    for i = #_orphans, 1, -1 do
        local pid = _orphans[i]
        if is_done(pid) then
            table.remove(_orphans, i)
            for key, in_pid in pairs(_in_flight) do
                if in_pid == pid then _in_flight[key] = nil end
            end
        end
    end
end


-- Is a background flush for `key` still alive?  Lazily clears a finished child
-- (so a stale entry can't wedge the book forever) before answering.
function BgFlush.in_flight(key, is_done)
    if not key then return false end
    local pid = _in_flight[key]
    if not pid then return false end
    if not is_done then
        local _, resolved = resolve(nil)
        is_done = resolved
    end
    if type(is_done) == "function" and is_done(pid) then
        _in_flight[key] = nil
        return false
    end
    return true
end


-- One low-rate sweep loop, armed when a guard parks a pid and disarmed once the
-- orphan list drains.  Without it a timed-out child that later exits stays a
-- zombie for the rest of the session unless another background flush happens to
-- start (codex): sweep_orphans() otherwise only runs from a future run().
local _sweep_armed = false
local function arm_orphan_sweep(scheduler, is_done, interval)
    if _sweep_armed then return end
    _sweep_armed = true
    local function sweep()
        BgFlush.sweep_orphans(is_done)
        if #_orphans > 0 then
            scheduler:scheduleIn(interval, sweep)
        else
            _sweep_armed = false
        end
    end
    scheduler:scheduleIn(interval, sweep)
end


-- Run `task` in a forked subprocess, polling for completion.
--
-- @param task    function  runs IN THE CHILD; net+disk only (see contract above)
-- @param on_done function? called ONCE in the parent: on_done(ok) — ok=true when
--                          the child was reaped, false when the guard fired
-- @param deps    table?    { fork, is_done, scheduler, flush, poll_interval,
--                            timeout, sweep_interval, logger, key }
--                          `key` (e.g. the book file) registers the child in
--                          the in-flight table; callers use BgFlush.in_flight()
--                          to decline overlapping flushes for the same book.
-- @return boolean  true if the work was backgrounded (async), false if fork is
--                  unavailable/failed — the caller MUST then run its synchronous
--                  fallback (on_done is NOT called in that case).
function BgFlush.run(task, on_done, deps)
    local fork, is_done, scheduler
    fork, is_done, scheduler, deps = resolve(deps)

    -- Can't background without all three primitives -> tell the caller to fall
    -- back to the synchronous path.
    if type(fork) ~= "function" or type(is_done) ~= "function"
            or type(scheduler) ~= "table"
            or type(scheduler.scheduleIn) ~= "function" then
        return false
    end

    -- Opportunistically reap any earlier orphan before spawning a new child.
    BgFlush.sweep_orphans(is_done)

    -- Spike-1 lesson: flush buffered stdout BEFORE fork, or the child inherits
    -- the unflushed buffer and re-emits it on exit (doubled log lines).
    local flush = deps.flush
    if flush == nil then flush = function() io.stdout:flush() end end
    if flush then pcall(flush) end

    local ok_fork, pid = pcall(fork, task, false, false)
    -- runInSubProcess returns false,err on failure; pcall guards a raise too.
    if not ok_fork or not pid or pid == false or type(pid) ~= "number" then
        return false
    end

    local key = deps.key
    if key then _in_flight[key] = pid end

    local interval = deps.poll_interval or 0.2
    -- Wall-clock guard: bound how long we keep polling for a stuck child.  Real
    -- syncs are seconds; the default is generous so a genuinely slow-but-live
    -- sync is never abandoned prematurely.
    local guard    = deps.timeout or 180
    local logger   = deps.logger
    local elapsed  = 0
    local finished = false

    local function finish(ok)
        if finished then return end
        finished = true
        if on_done then pcall(on_done, ok) end
    end

    local function poll()
        if is_done(pid) then
            if key and _in_flight[key] == pid then _in_flight[key] = nil end
            finish(true)
            return
        end
        elapsed = elapsed + interval
        if elapsed >= guard then
            -- Give up waiting, but don't SIGKILL: the child may simply be a slow
            -- (live) sync, and on e-ink our poller ticks lazily so `elapsed` can
            -- overcount idle time.  Park the pid for a later sweep to reap, and
            -- report not-ok so the caller can proceed (e.g. shut the transport).
            -- The in-flight key is NOT cleared here — the child may still be
            -- transferring, so the book stays guarded until a sweep reaps it.
            _orphans[#_orphans + 1] = pid
            arm_orphan_sweep(scheduler, is_done, deps.sweep_interval or 60)
            if logger and logger.warn then
                logger.warn("Syncery: bg_flush guard fired, pid parked for reap")
            end
            finish(false)
            return
        end
        scheduler:scheduleIn(interval, poll)
    end

    scheduler:scheduleIn(interval, poll)
    return true
end


return BgFlush
