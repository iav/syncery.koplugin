-- =============================================================================
-- spec/read_time_carry_spec.lua
-- =============================================================================
--
-- Unit tests for the "carry last-read time" helpers in syncery_util.lua:
--
--   * Util.newest_read_time — pure: the newest per-device position-move
--     timestamp in a merged progress state.  This is what should drive
--     KOReader's "last read date" sort, NOT the moment a sync ran.
--   * Util.stamp_read_time  — writes atime (preserving mtime) via lfs.touch.
--
-- The point of the feature: a sync -- or the reopen a post-sync reload
-- performs -- must not masquerade as fresh reading.  These helpers let
-- main.lua's _writeSave stamp the genuine last-read time instead.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local Util = require("syncery_util")


-- ── Util.newest_read_time ────────────────────────────────────────────────

local function state(entries)
    return { schema_version = 1, entries = entries }
end

-- nil / malformed input yields nil (helper is best-effort).
h.assert_nil(Util.newest_read_time(nil), "nil state")
h.assert_nil(Util.newest_read_time({}), "state without entries")
h.assert_nil(Util.newest_read_time(state("nope")), "entries not a table")
h.assert_nil(Util.newest_read_time(state({})), "empty entries")

-- A truthy NON-table state must not raise on the index (would abort the
-- caller's save pcall after progress was written).
h.assert_nil(Util.newest_read_time(5), "numeric state does not raise")
h.assert_nil(Util.newest_read_time("garbage"), "string state does not raise")
h.assert_nil(Util.newest_read_time(true), "boolean state does not raise")

-- Single device: its timestamp.
h.assert_equal(
    Util.newest_read_time(state({ dev1 = { timestamp = 1000 } })),
    1000, "single device timestamp")

-- Multiple devices: the NEWEST wins (carry a peer's later read forward).
h.assert_equal(
    Util.newest_read_time(state({
        dev1 = { timestamp = 1000 },
        dev2 = { timestamp = 3000 },
        dev3 = { timestamp = 2000 },
    })),
    3000, "newest across devices")

-- Our own newer read stays ours (not overwritten by an older peer).
h.assert_equal(
    Util.newest_read_time(state({
        me   = { timestamp = 5000 },
        peer = { timestamp = 4000 },
    })),
    5000, "our newer read wins over older peer")

-- Entries missing / with non-numeric timestamps are ignored, not fatal.
h.assert_equal(
    Util.newest_read_time(state({
        dev1 = { timestamp = 2000 },
        dev2 = { percent = 0.5 },          -- no timestamp
        dev3 = "garbage",                   -- not a table
        dev4 = { timestamp = "later" },     -- non-numeric
    })),
    2000, "ignores entries without a numeric timestamp")

-- String-numeric timestamps coerce (defensive; JSON round-trips numbers).
h.assert_equal(
    Util.newest_read_time(state({ dev1 = { timestamp = "1500" } })),
    1500, "coerces numeric string timestamp")


-- ── Util.stamp_read_time ─────────────────────────────────────────────────

-- Swap in a recording fake lfs so the test is deterministic and touches no
-- real files.  Util.get_lfs re-requires each call, so overriding
-- package.loaded is enough.
local real_lfs = package.loaded["libs/libkoreader-lfs"]
local recorded
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_, key)
        if key == "modification" then return 8888 end
        return nil
    end,
    touch = function(path, atime, mtime)
        recorded = { path = path, atime = atime, mtime = mtime }
        return true
    end,
}

-- Happy path: atime = ts, mtime preserved (independent "date modified" sort
-- must not be corrupted).
recorded = nil
h.assert_true(Util.stamp_read_time("/books/foo.fb2", 1234), "stamp returns true")
h.assert_equal(recorded.path,  "/books/foo.fb2", "touched the right path")
h.assert_equal(recorded.atime, 1234,             "atime = read timestamp")
h.assert_equal(recorded.mtime, 8888,             "mtime preserved")

-- Guards: no path, non-positive / non-number ts -> no touch, returns false.
recorded = nil
h.assert_false(Util.stamp_read_time(nil, 1234),        "nil path")
h.assert_false(Util.stamp_read_time("/x", 0),          "zero ts")
h.assert_false(Util.stamp_read_time("/x", -5),         "negative ts")
h.assert_false(Util.stamp_read_time("/x", "nope"),     "non-number ts")
h.assert_nil(recorded, "guarded calls never touch")

-- Missing file (attributes returns nil for modification) -> no touch.
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    touch = function() recorded = "SHOULD NOT HAPPEN"; return true end,
}
recorded = nil
h.assert_false(Util.stamp_read_time("/gone.fb2", 1234), "missing file -> false")
h.assert_nil(recorded, "missing file never touches")

-- touch that fails WITHOUT throwing (read-only / permission-denied returns
-- nil+err) must be reported as failure, not swallowed as success by pcall.
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_, key) return key == "modification" and 8888 or nil end,
    touch = function() return nil, "Permission denied" end,
}
h.assert_false(Util.stamp_read_time("/readonly.fb2", 1234),
    "touch returning nil+err -> false, not a false success")

package.loaded["libs/libkoreader-lfs"] = real_lfs

h.report("read_time_carry_spec")
