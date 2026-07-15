-- =============================================================================
-- spec/push_opened_books_spec.lua
-- =============================================================================
-- Tests pushOpenedBooks: .opened file parsing, dedup, push per unique
-- book, clear on success, preserve on cloud-unreachable.
-- Requires real files on disk because do_cloud_upload reads them.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_push_opened_spec_" .. tostring(os.time()))

-- Stub settings
package.loaded["syncery_settings"] = {
    is_cloud_configured = function() return true end,
    get_cloud_server    = function() return { type = "webdav", url = "https://test.local" } end,
}

local ProgressPaths = require("syncery_progress/paths")
local PluginSync     = require("syncery_transports/plugin_sync")


local function make_plugin(opts)
    opts = opts or {}
    local base = h.test_root .. "/"
    local p = {
        use_cloud        = true,
        state_dir        = base,
        destroyed        = false,
        _online          = opts.online ~= false,
        _cloud_online    = opts.cloud_online ~= false,
        _calls           = {},
        ui               = { document = { file = base .. "book.epub" } },
        -- This spec's own concern is push DISPATCH counting/ordering, not
        -- the per-kind toggle gates 
        -- default all sync
        -- toggles on so existing fixtures here keep exercising the SAME
        -- push-dispatch behavior as before, unaffected by that fix.
        sync_progress         = opts.sync_progress ~= false,
        sync_annotations      = opts.sync_annotations ~= false,
        sync_metadata         = opts.sync_metadata ~= false,
        sync_render_settings  = opts.sync_render_settings ~= false,
    }

    function p:_isNetworkOnline()  return self._online end
    function p:_isCloudReachable() return self._cloud_online end
    function p:getCurrentState()   return { file = opts.file or base .. "book.epub" } end
    function p:_isFileTypeSynced() return true end

    -- Fix 4's content-hash push cache lives on disk under state_dir and
    -- would otherwise persist ACROSS this file's separate do{} blocks
    -- (they all share the same h.test_root). Each block here represents
    -- an independent scenario, several reusing the same book paths with
    -- the same fixed content (write_progress always writes the identical
    -- string) -- without clearing the cache fresh per make_plugin() call,
    -- a LATER block's push would be wrongly skipped as "unchanged from
    -- an EARLIER, unrelated block", which is a test-fixture artifact, not
    -- the real-world case the cache is meant to catch.
    require("syncery_transports/plugin_sync")._write_push_cache(p, {})

    -- Controllable per-book failure counts, simulating the
    -- Orchestrator's own peek_transport_books introspection
    -- tests bump p._failure_counts[file]
    -- to simulate "this specific push attempt genuinely failed at the
    -- network level", independent of do_cloud_upload's own "dispatched"
    -- return value.
    p._failure_counts = {}
    p._transport = {
        push_cloud_files = function(_, file, entries, ds)
            table.insert(p._calls, { m = "push", file = file, n = #entries })
        end,
        peek_transport_books = function(_, transport_id)
            local out = {}
            for file, count in pairs(p._failure_counts) do
                out[#out + 1] = { book_file = file, state = { consecutive_failures = count } }
            end
            return out
        end,
    }

    p._cloud_wifi_backoff = {
        attempt = function(_, a)
            table.insert(p._calls, { m = "cloud_wifi_attempt", label = a.label })
        end,
    }

    function p:write_opened(lines)
        local path = self.state_dir .. ".opened"
        local f = io.open(path, "w")
        if f then for _, l in ipairs(lines) do f:write(l .. "\n") end; f:close() end
    end

    function p:read_opened()
        local path = self.state_dir .. ".opened"
        local result = {}
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local book = line:gsub("%s+$", "")
                if book ~= "" then table.insert(result, book) end
            end
            f:close()
        end
        return result
    end

    function p:write_progress(filepath)
        local ppath = ProgressPaths.shared_progress_path(filepath)
        if ppath then
            -- ensure dir exists
            local dir = ppath:match("(.*)/")
            if dir then os.execute("mkdir -p '" .. dir .. "' 2>/dev/null") end
            local f = io.open(ppath, "w")
            if f then f:write('{"page":1,"percent":0.05}'); f:close() end
        end
    end

    return p
end


-- ===========================================================================
-- 1. Empty .opened → no push
-- ===========================================================================
do
    local p = make_plugin{}
    p:write_opened({})
    PluginSync.pushOpenedBooks(p)
    local pushes = 0
    for _, c in ipairs(p._calls) do if c.m == "push" then pushes = pushes + 1 end end
    h.assert_equal(pushes, 0, "empty .opened → zero pushes")
end


-- ===========================================================================
-- 2. No .opened file → safe no-op
-- ===========================================================================
do
    local p = make_plugin{}
    os.remove(p.state_dir .. ".opened")
    PluginSync.pushOpenedBooks(p)
    h.assert_true(true, "missing .opened → no crash")
end


-- ===========================================================================
-- 3. Single book with progress on disk → one push, .opened cleared
-- ===========================================================================
do
    local p = make_plugin{ file = p and p.state_dir and (p.state_dir .. "b.epub") }
    p = make_plugin{}
    local path = p.state_dir
    -- Write progress file so do_cloud_upload has something to push
    p:write_progress(path .. "book_a.epub")
    p:write_opened({ path .. "book_a.epub" })
    PluginSync.pushOpenedBooks(p)

    local pushed = {}
    for _, c in ipairs(p._calls) do
        if c.m == "push" then table.insert(pushed, c.file) end
    end
    h.assert_equal(#pushed, 1, "one book with progress → one push")
    if #pushed > 0 then
        h.assert_equal(pushed[1], path .. "book_a.epub")
    end
    local remaining = p:read_opened()
    h.assert_equal(#remaining, 0, "success → .opened cleared")
end


-- ===========================================================================
-- 4. Duplicate lines → dedup, push once per unique
-- ===========================================================================
do
    local p = make_plugin{}
    local path = p.state_dir
    p:write_progress(path .. "a.epub")
    p:write_progress(path .. "b.epub")
    p:write_opened({
        path .. "a.epub", path .. "a.epub",
        path .. "b.epub", path .. "a.epub",
    })
    PluginSync.pushOpenedBooks(p)

    local pushed = {}
    for _, c in ipairs(p._calls) do
        if c.m == "push" then table.insert(pushed, c.file) end
    end
    h.assert_equal(#pushed, 2, "4 entries (3 dup a + 1 b) → 2 pushes")
end


-- ===========================================================================
-- 5. Cloud unreachable → deferred, .opened preserved
-- ===========================================================================
do
    local p = make_plugin{ cloud_online = false }
    p:write_opened({ p.state_dir .. "a.epub" })
    PluginSync.pushOpenedBooks(p)

    local pushed = 0
    for _, c in ipairs(p._calls) do if c.m == "push" then pushed = pushed + 1 end end
    h.assert_equal(pushed, 0, "cloud offline → no pushes")

    local backoff = false
    for _, c in ipairs(p._calls) do if c.m == "cloud_wifi_attempt" then backoff = true end end
    h.assert_true(backoff, "cloud offline → backoff scheduled")
end


-- ===========================================================================
-- 6. Multiple books → all pushed, .opened cleared
-- ===========================================================================
do
    local p = make_plugin{}
    local path = p.state_dir
    local books = {}
    for i = 1, 5 do
        books[i] = path .. "book_" .. i .. ".epub"
        p:write_progress(books[i])
    end
    p:write_opened(books)
    PluginSync.pushOpenedBooks(p)

    local pushed = 0
    for _, c in ipairs(p._calls) do if c.m == "push" then pushed = pushed + 1 end end
    h.assert_equal(pushed, 5, "5 books → 5 pushes")
    h.assert_equal(#p:read_opened(), 0, "success → .opened empty")
end


-- ===========================================================================
-- 7. info_fn abort mid-loop → only attempted books pushed, the rest
--    (not-yet-reached) stay queued in .opened -- NOT dropped as if
--    they'd synced.  Exercises the Trapper-wrap escape hatch added to
--    sync_all's Phase 1 (pushOpenedBooks now takes an optional info_fn;
--    teardown.lua's call site passes none and is covered by tests 1-6
--    above, which are all still calling pushOpenedBooks(p) unchanged).
-- ===========================================================================
do
    local p = make_plugin{}
    local path = p.state_dir
    local books = {}
    for i = 1, 3 do
        books[i] = path .. "abort_" .. i .. ".epub"
        p:write_progress(books[i])
    end
    p:write_opened(books)

    local calls = 0
    local info_fn = function(_msg)
        calls = calls + 1
        return calls < 2   -- allow book #1's gate, abort before book #2
    end
    PluginSync.pushOpenedBooks(p, info_fn)

    local pushed = 0
    for _, c in ipairs(p._calls) do if c.m == "push" then pushed = pushed + 1 end end
    h.assert_equal(pushed, 1, "abort after book 1 → only 1 pushed")
    h.assert_equal(#p:read_opened(), 2, "abort → 2 not-yet-attempted books preserved")
end


-- ===========================================================================
-- 8. plugin.destroyed becomes true mid-loop → same preservation as an
--    explicit abort (checked before each info_fn call, not just at entry).
-- ===========================================================================
do
    local p = make_plugin{}
    local path = p.state_dir
    local books = {}
    for i = 1, 2 do
        books[i] = path .. "destroyed_" .. i .. ".epub"
        p:write_progress(books[i])
    end
    p:write_opened(books)

    local calls = 0
    local info_fn = function(_msg)
        calls = calls + 1
        if calls == 1 then p.destroyed = true end
        return true
    end
    PluginSync.pushOpenedBooks(p, info_fn)

    local pushed = 0
    for _, c in ipairs(p._calls) do if c.m == "push" then pushed = pushed + 1 end end
    h.assert_equal(pushed, 1, "destroyed after book 1's gate → only 1 pushed")
    h.assert_equal(#p:read_opened(), 1, "destroyed mid-loop → 1 not-yet-attempted book preserved")
end


-- ===========================================================================
-- 9. info_fn present but never aborts → identical outcome to the no-
--    info_fn path (all pushed, .opened cleared) -- the new parameter is
--    additive, not a behaviour change for the happy path.
-- ===========================================================================
do
    local p = make_plugin{}
    local path = p.state_dir
    p:write_progress(path .. "happy_1.epub")
    p:write_progress(path .. "happy_2.epub")
    p:write_opened({ path .. "happy_1.epub", path .. "happy_2.epub" })

    PluginSync.pushOpenedBooks(p, function(_msg) return true end)

    local pushed = 0
    for _, c in ipairs(p._calls) do if c.m == "push" then pushed = pushed + 1 end end
    h.assert_equal(pushed, 2, "info_fn present, no abort → both pushed")
    h.assert_equal(#p:read_opened(), 0, "info_fn present, no abort → .opened cleared")
end


-- ===========================================================================
-- 10. only_book: narrows to ONE book, leaves every OTHER queued book
--     untouched in .opened (not cleared, not treated as failed) --
--     exercises teardown.lua's bounded Step 3 push (state.file only,
--     never the whole worklist -- see teardown.lua's own comment on
--     why an unbounded flush there would be bad UX with no Trapper
--     progress/abort available).
-- ===========================================================================
do
    local p = make_plugin{}
    local path = p.state_dir
    p:write_progress(path .. "current.epub")
    p:write_progress(path .. "other_a.epub")
    p:write_progress(path .. "other_b.epub")
    p:write_opened({ path .. "current.epub", path .. "other_a.epub", path .. "other_b.epub" })

    PluginSync.pushOpenedBooks(p, nil, path .. "current.epub")

    local pushed = {}
    for _, c in ipairs(p._calls) do
        if c.m == "push" then table.insert(pushed, c.file) end
    end
    h.assert_equal(#pushed, 1, "only_book → exactly 1 push")
    h.assert_equal(pushed[1], path .. "current.epub", "only_book → pushed THIS book, not the others")

    local remaining = p:read_opened()
    h.assert_equal(#remaining, 2, "only_book → the 2 other queued books are preserved, not dropped")
end


-- ===========================================================================
-- 11. only_book, but that book is NOT in the worklist -> no-op, the
--     rest of .opened is left completely alone.
-- ===========================================================================
do
    local p = make_plugin{}
    local path = p.state_dir
    p:write_progress(path .. "queued.epub")
    p:write_opened({ path .. "queued.epub" })

    PluginSync.pushOpenedBooks(p, nil, path .. "not_queued.epub")

    local pushed = 0
    for _, c in ipairs(p._calls) do if c.m == "push" then pushed = pushed + 1 end end
    h.assert_equal(pushed, 0, "only_book not in worklist → no push at all")
    h.assert_equal(#p:read_opened(), 1, "only_book not in worklist → .opened untouched")
end


-- ===========================================================================
-- 12. only_book that FAILS to push -> stays queued alongside the
--     untouched others (failure and "narrowed-out" both end up back in
--     .opened, for exactly the same reason: not yet actually synced).
-- ===========================================================================
do
    local p = make_plugin{ cloud_online = true }
    local path = p.state_dir
    -- No progress/annotations content staged for this book -> do_cloud_upload
    -- finds nothing to push and returns nil (not "deferred"), which
    -- pushOpenedBooks' pcall treats as `ok=true, status=nil` -- i.e. NOT
    -- appended to `failed`.  To force a real failure, make push_cloud_files
    -- itself raise.
    p:write_progress(path .. "will_fail.epub")
    p:write_opened({ path .. "will_fail.epub", path .. "kept_too.epub" })
    p._transport.push_cloud_files = function() error("simulated push failure") end

    PluginSync.pushOpenedBooks(p, nil, path .. "will_fail.epub")

    local remaining = p:read_opened()
    table.sort(remaining)
    local expected = { path .. "kept_too.epub", path .. "will_fail.epub" }
    table.sort(expected)
    h.assert_equal(#remaining, 2, "only_book failed → both the failed book AND the untouched one remain")
    h.assert_equal(remaining[1], expected[1], "remaining set matches (entry 1)")
    h.assert_equal(remaining[2], expected[2], "remaining set matches (entry 2)")
end


-- ---------------------------------------------------------------------------
-- Fix 2: pushOpenedBooks now RETURNS the
-- list of books it successfully pushed this round, so sync_all's Phase 2
-- can exclude them from the "changed vs peer" comparison -- a book just
-- pushed moments ago in Phase 1 would otherwise show up as "changed"
-- there too (our own hash just changed relative to the peer's stale
-- copy) and get a second, redundant push+pull in the SAME Sync Now.
-- This test covers the return value in isolation; the exclusion these
-- book_ids feed into is deep inside sync_all's multi-peer manifest loop
-- and is covered instead by this design's own two-device simulation
-- harness (spec/two_device_redundancy_investigation.lua, not part of
-- this pass/fail suite), which reproduces the double-push end-to-end
-- with a real Bridge/Orchestrator/Transport chain.
-- ---------------------------------------------------------------------------

do
    local p = make_plugin{}
    local path = p.state_dir
    p:write_progress(path .. "ret_a.epub")
    p:write_progress(path .. "ret_b.epub")
    p:write_opened({ path .. "ret_a.epub", path .. "ret_b.epub" })
    local succeeded = PluginSync.pushOpenedBooks(p)
    table.sort(succeeded)
    h.assert_equal(#succeeded, 2, "pushOpenedBooks returns both successfully pushed books")
    h.assert_equal(succeeded[1], path .. "ret_a.epub", "returned set includes the first book")
    h.assert_equal(succeeded[2], path .. "ret_b.epub", "returned set includes the second book")
end

do
    -- A book whose push fails (deferred) must NOT appear in the returned
    -- successful set.
    local p = make_plugin{ cloud_online = false }
    local path = p.state_dir
    p:write_progress(path .. "ret_fail.epub")
    p:write_opened({ path .. "ret_fail.epub" })
    local succeeded = PluginSync.pushOpenedBooks(p)
    h.assert_equal(#succeeded, 0,
        "pushOpenedBooks returns an empty set when the only queued book's push is deferred")
end

do
    -- No .opened file at all -- must return an empty table, not nil (so
    -- callers can safely ipairs() over it without a nil-guard).
    local p = make_plugin{}
    os.remove(p.state_dir .. ".opened")
    local succeeded = PluginSync.pushOpenedBooks(p)
    h.assert_true(type(succeeded) == "table" and #succeeded == 0,
        "pushOpenedBooks returns an empty table (not nil) when there is nothing queued")
end


-- ---------------------------------------------------------------------------
-- Fix 1: do_cloud_upload's "dispatched"
-- return does not mean the push actually reached the server -- a
-- mid-flight network failure (distinct from the upfront-unreachable
-- "deferred" case) used to still get the book cleared from .opened as if
-- it had succeeded. Fix reads the Orchestrator's own pre-existing
-- peek_transport_books introspection (consecutive_failures) immediately
-- before and after dispatch; an increase means THIS attempt genuinely
-- failed, regardless of the "dispatched" string.
-- ---------------------------------------------------------------------------

do
    -- Simulate a push whose underlying network call fails mid-flight:
    -- push_cloud_files still runs (do_cloud_upload still returns
    -- "dispatched"), but consecutive_failures goes 0 -> 1 for this book,
    -- exactly like a real Orchestrator would record for a genuine
    -- failure.
    local p = make_plugin{}
    local path = p.state_dir
    p:write_progress(path .. "fix1_fail.epub")
    p:write_opened({ path .. "fix1_fail.epub" })

    local real_push = p._transport.push_cloud_files
    p._transport.push_cloud_files = function(self, file, entries, ds)
        real_push(self, file, entries, ds)
        p._failure_counts[file] = (p._failure_counts[file] or 0) + 1
    end

    local succeeded = PluginSync.pushOpenedBooks(p)
    h.assert_equal(#succeeded, 0,
        "fix1: a book whose push genuinely fails mid-flight is NOT in the succeeded set")

    local remaining = p:read_opened()
    h.assert_equal(#remaining, 1,
        "fix1: the genuinely-failed book stays queued in .opened for the next Sync Now")
    h.assert_equal(remaining[1], path .. "fix1_fail.epub")
end

do
    -- Sanity check the OTHER direction: a normal, genuinely successful
    -- push (consecutive_failures stays at 0, or the book has no prior
    -- entry at all) must still clear .opened as before -- Fix 1 must not
    -- make a healthy push look like a failure.
    local p = make_plugin{}
    local path = p.state_dir
    p:write_progress(path .. "fix1_ok.epub")
    p:write_opened({ path .. "fix1_ok.epub" })

    local succeeded = PluginSync.pushOpenedBooks(p)
    h.assert_equal(#succeeded, 1, "fix1: a genuinely successful push is still counted as succeeded")
    local remaining = p:read_opened()
    h.assert_equal(#remaining, 0, "fix1: a genuinely successful push still clears .opened")
end

do
    -- A transport that does not implement peek_transport_books at all
    -- (defensive fallback) must not raise, and must preserve the
    -- PRE-FIX behavior (treat dispatch as success) rather than break.
    local p = make_plugin{}
    local path = p.state_dir
    p._transport.peek_transport_books = nil
    p:write_progress(path .. "fix1_no_peek.epub")
    p:write_opened({ path .. "fix1_no_peek.epub" })

    local ok_call, succeeded = pcall(PluginSync.pushOpenedBooks, p)
    h.assert_true(ok_call, "fix1: a transport without peek_transport_books does not raise")
    h.assert_equal(#succeeded, 1,
        "fix1: without peek_transport_books, falls back to treating dispatch as success")
end


h.teardown()
