-- =============================================================================
-- spec/bg_flush_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/bg_flush.lua — the subprocess-fork runner that
-- takes the synchronous cloud sync off the UI thread on close.
--
-- No real fork/UIManager here: every dependency is injected.  A fake `fork`
-- records the task and hands back a pid; a controllable `is_done` decides when
-- the child appears reaped; a fake scheduler (object with :scheduleIn, wrapping
-- the shared make_fake_scheduler) drives the poll loop under a fake clock.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_bg_flush_spec_" .. tostring(os.time()))

local BgFlush = require("syncery_transports/bg_flush")


-- UIManager-shaped scheduler (:scheduleIn) wrapping the shared fake scheduler.
local function make_scheduler(clock)
    local s = h.make_fake_scheduler(clock)
    return {
        scheduleIn    = function(_self, delay, fn) s.schedule(delay, fn) end,
        run_due       = s.run_due,
        run_all       = s.run_all,
        pending_count = s.pending_count,
    }
end

-- Fake fork: records the call, returns the configured pid (or false to simulate
-- a fork failure).
local function make_fork(pid_or_false)
    local rec = { calls = 0 }
    rec.fork = function(task, with_pipe, double_fork)
        rec.calls       = rec.calls + 1
        rec.task        = task
        rec.with_pipe   = with_pipe
        rec.double_fork = double_fork
        return pid_or_false
    end
    return rec
end

-- Controllable is_done: reports "not done" until it has been asked `done_after`
-- times for that pid, then "done".  done_after = math.huge => never done.
local function make_is_done(done_after)
    local n = 0
    return function(_pid)
        n = n + 1
        return n > done_after
    end
end


-- ----------------------------------------------------------------------------
-- Fork unavailable -> false, and on_done is never called (caller must fall back).
-- ----------------------------------------------------------------------------
do
    local clock = h.make_fake_clock(0)
    local sched = make_scheduler(clock)
    local done_called = false

    local launched = BgFlush.run(function() end,
        function() done_called = true end,
        { fork = nil, is_done = function() return true end, scheduler = sched })

    h.assert_false(launched, "no fork fn -> not backgrounded")
    h.assert_false(done_called, "on_done NOT called on fallback")
    h.assert_equal(sched.pending_count(), 0, "nothing scheduled")
end


-- ----------------------------------------------------------------------------
-- Scheduler without scheduleIn -> false.
-- ----------------------------------------------------------------------------
do
    local fk = make_fork(123)
    local launched = BgFlush.run(function() end, nil,
        { fork = fk.fork, is_done = function() return true end,
          scheduler = { not_a_scheduler = true } })
    h.assert_false(launched, "bad scheduler -> not backgrounded")
    h.assert_equal(fk.calls, 0, "fork not attempted without a usable scheduler")
end


-- ----------------------------------------------------------------------------
-- Fork itself fails (returns false) -> false, no polling, no on_done.
-- ----------------------------------------------------------------------------
do
    local clock = h.make_fake_clock(0)
    local sched = make_scheduler(clock)
    local fk = make_fork(false)
    local done_called = false

    local launched = BgFlush.run(function() end,
        function() done_called = true end,
        { fork = fk.fork, is_done = function() return true end, scheduler = sched })

    h.assert_false(launched, "fork returning false -> not backgrounded")
    h.assert_equal(fk.calls, 1, "fork was attempted once")
    h.assert_false(done_called, "on_done NOT called when fork failed")
    h.assert_equal(sched.pending_count(), 0, "no poller scheduled")
end


-- ----------------------------------------------------------------------------
-- Happy path: launched=true; child not done at first poll; on_done(true) fires
-- exactly once once is_done flips; fork args are (task, false, false).
-- ----------------------------------------------------------------------------
do
    local clock = h.make_fake_clock(0)
    local sched = make_scheduler(clock)
    local fk = make_fork(777)
    local the_task = function() end
    local done_calls, done_ok = 0, nil

    local launched = BgFlush.run(the_task,
        function(ok) done_calls = done_calls + 1; done_ok = ok end,
        { fork = fk.fork, is_done = make_is_done(1), scheduler = sched,
          poll_interval = 0.2, flush = function() end })

    h.assert_true(launched, "backgrounded")
    h.assert_equal(fk.task, the_task, "task forwarded to fork verbatim")
    h.assert_false(fk.with_pipe, "with_pipe = false")
    h.assert_false(fk.double_fork, "double_fork = false")
    h.assert_equal(sched.pending_count(), 1, "one poller queued")

    -- First poll: is_done() -> false (call #1) -> reschedules, not done yet.
    clock.advance(0.2); sched.run_due()
    h.assert_equal(done_calls, 0, "not done after first poll")
    h.assert_equal(sched.pending_count(), 1, "poller rescheduled")

    -- Second poll: is_done() -> true (call #2) -> on_done(true).
    clock.advance(0.2); sched.run_due()
    h.assert_equal(done_calls, 1, "on_done fired once")
    h.assert_true(done_ok, "on_done(true) on clean reap")
    h.assert_equal(sched.pending_count(), 0, "no more polling after done")

    -- Draining any stragglers must not re-fire on_done.
    sched.run_all()
    h.assert_equal(done_calls, 1, "on_done still called exactly once")
end


-- ----------------------------------------------------------------------------
-- flush() runs BEFORE the fork (spike-1 lesson: avoid inherited-buffer doubling).
-- ----------------------------------------------------------------------------
do
    local clock = h.make_fake_clock(0)
    local sched = make_scheduler(clock)
    local order = {}
    local fk = { fork = function(_t) order[#order+1] = "fork"; return 5 end }

    BgFlush.run(function() end, nil,
        { fork = fk.fork, is_done = function() return true end, scheduler = sched,
          flush = function() order[#order+1] = "flush" end })

    h.assert_equal(order[1], "flush", "flush happens first")
    h.assert_equal(order[2], "fork",  "fork happens after flush")
end


-- ----------------------------------------------------------------------------
-- in_flight: a keyed child is busy until reaped; lazy clear via is_done.
-- ----------------------------------------------------------------------------
do
    local clock = h.make_fake_clock(0)
    local sched = make_scheduler(clock)
    local fk = make_fork(77)
    local alive = true
    local is_done = function() return not alive end

    BgFlush.run(function() end, nil,
        { fork = fk.fork, is_done = is_done, scheduler = sched,
          poll_interval = 0.2, timeout = 10, flush = function() end,
          key = "/books/a.epub" })
    h.assert_true(BgFlush.in_flight("/books/a.epub", is_done),
        "keyed child reported busy while alive")
    h.assert_false(BgFlush.in_flight("/books/b.epub", is_done),
        "an unrelated key is free")

    alive = false
    h.assert_false(BgFlush.in_flight("/books/a.epub", is_done),
        "lazily cleared once the child is done")
end


-- ----------------------------------------------------------------------------
-- Guard fires: child never reaped -> on_done(false) once, pid parked as orphan,
-- and a LOW-RATE sweep loop is armed so the pid is reaped even if no new flush
-- ever starts (codex).  (Kept last: touches module-level orphan list.)
-- ----------------------------------------------------------------------------
do
    h.assert_equal(BgFlush._orphan_count(), 0, "no orphans before guard test")

    local clock = h.make_fake_clock(0)
    local sched = make_scheduler(clock)
    local fk = make_fork(999)
    local done_calls, done_ok = 0, nil

    local launched = BgFlush.run(function() end,
        function(ok) done_calls = done_calls + 1; done_ok = ok end,
        { fork = fk.fork, is_done = make_is_done(math.huge), scheduler = sched,
          poll_interval = 0.2, timeout = 1.0, flush = function() end })
    h.assert_true(launched, "backgrounded")

    -- Poll repeatedly; is_done stays false, so elapsed climbs to the 1.0s guard
    -- (0.2 * 5 = 1.0).  Fire enough ticks to cross it.
    for _ = 1, 10 do
        clock.advance(0.2); sched.run_due()
    end
    h.assert_equal(done_calls, 1, "on_done fired once via guard")
    h.assert_false(done_ok, "on_done(false) when guard fires")
    h.assert_equal(sched.pending_count(), 1, "sweep loop armed after guard")
    h.assert_equal(BgFlush._orphan_count(), 1, "pid parked for later reap")

    -- First sweep tick: the child is still alive -> orphan stays, loop re-arms.
    clock.advance(60); sched.run_due()
    h.assert_equal(BgFlush._orphan_count(), 1, "still parked while child alive")
    h.assert_equal(sched.pending_count(), 1, "sweep loop re-armed")

    -- Child finally exits: a sweep with a reaping is_done clears the orphan,
    -- and the armed loop disarms on its next (empty) tick.
    BgFlush.sweep_orphans(function() return true end)
    h.assert_equal(BgFlush._orphan_count(), 0, "orphan reaped by sweep")
    clock.advance(60); sched.run_due()
    h.assert_equal(sched.pending_count(), 0, "sweep loop disarmed once drained")
end


h.report("bg_flush")
