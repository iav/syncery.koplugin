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
    }

    function p:_isNetworkOnline()  return self._online end
    function p:_isCloudReachable() return self._cloud_online end
    function p:getCurrentState()   return { file = opts.file or base .. "book.epub" } end
    function p:_isFileTypeSynced() return true end

    p._transport = {
        push_cloud_files = function(_, file, entries, ds)
            table.insert(p._calls, { m = "push", file = file, n = #entries })
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


h.teardown()