-- =============================================================================
-- spec/cloud_prefetch_spec.lua
-- =============================================================================
--
-- Unit tests for Checkpoint 1 of the cloud prefetch design
-- (docs/CLOUD_PREFETCH_DESIGN.md, v18): the book_id safety gate, remote
-- listing grouping, and validated-write primitives shared by both
-- transport paths.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local PluginSync = require("syncery_transports/plugin_sync")


-- ── _isSafeBookId (Constraint X — security-critical, test first) ───────────

h.assert_true(PluginSync._isSafeBookId("9AFFCFE4A34647A08208E4D610DF10C3"),
    "normal hex book_id accepted")
h.assert_true(PluginSync._isSafeBookId("abc-123_ABC"),
    "hyphen/underscore accepted")
h.assert_false(PluginSync._isSafeBookId("../../../etc/passwd"),
    "path traversal rejected")
h.assert_false(PluginSync._isSafeBookId("/etc/passwd"),
    "absolute path rejected")
h.assert_false(PluginSync._isSafeBookId("a/b"),
    "embedded slash rejected")
h.assert_false(PluginSync._isSafeBookId(""),
    "empty string rejected")
h.assert_false(PluginSync._isSafeBookId(nil),
    "nil rejected")
h.assert_false(PluginSync._isSafeBookId(12345),
    "non-string rejected")


-- ── _groupRemoteEntries (Constraint Q) ──────────────────────────────────────

local function entry(text, filesize)
    return { text = text, filesize = filesize }
end

do
    local entries = {
        entry("syncery-progress-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.json", 100),
        entry("syncery-annotations-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.json", 200),
        entry("syncery-progress-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB.json", 50),
        entry("syncery-manifest-somedevice.txt", 10),      -- different kind, ignored
        entry("random-file.txt", 5),                        -- non-matching, ignored
        entry("syncery-progress-../../../etc/passwd.json", 999), -- unsafe, ignored
    }
    local grouped = PluginSync._groupRemoteEntries(entries)

    h.assert_true(grouped["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"] ~= nil,
        "book A grouped")
    h.assert_equal(grouped["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"].progress.filesize, 100,
        "book A progress filesize carried through")
    h.assert_equal(grouped["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"].annotations.filesize, 200,
        "book A annotations filesize carried through")
    h.assert_true(grouped["BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"] ~= nil,
        "book B grouped (progress only)")
    h.assert_nil(grouped["BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"].annotations,
        "book B has no annotations entry")

    local unsafe_count = 0
    for book_id in pairs(grouped) do
        if book_id:match("[^%w%-_]") then unsafe_count = unsafe_count + 1 end
    end
    h.assert_equal(unsafe_count, 0,
        "no unsafe book_id ever entered the grouped table")
end


-- ── _validateAndPlace (Constraints I, J) ────────────────────────────────────

local test_dir = "/tmp/cloud_prefetch_spec_" .. tostring(os.time())
os.execute("mkdir -p " .. test_dir)

do
    local final_path = test_dir .. "/valid.json"
    local ok = PluginSync._validateAndPlace('{"a":1}', final_path)
    h.assert_true(ok, "valid JSON content placed successfully")
    local f = io.open(final_path, "rb")
    h.assert_true(f ~= nil, "final file exists after placement")
    if f then
        h.assert_equal(f:read("*a"), '{"a":1}', "final file content matches")
        f:close()
    end
    h.assert_true(io.open(final_path .. ".tmp") == nil,
        "temp file does not linger after a successful placement")
end

do
    local final_path = test_dir .. "/empty.json"
    local ok, err = PluginSync._validateAndPlace("", final_path)
    h.assert_false(ok, "empty content rejected")
    h.assert_true(err ~= nil, "error message returned for empty content")
    h.assert_true(io.open(final_path) == nil,
        "no file written for empty content")
end

do
    local final_path = test_dir .. "/invalid.json"
    local ok, err = PluginSync._validateAndPlace("not json {{{", final_path)
    h.assert_false(ok, "invalid JSON rejected")
    h.assert_true(err ~= nil, "error message returned for invalid JSON")
    h.assert_true(io.open(final_path) == nil,
        "no file written for invalid JSON")
    h.assert_true(io.open(final_path .. ".tmp") == nil,
        "temp file cleaned up after invalid-JSON rejection")
end

os.execute("rm -rf " .. test_dir)


-- ── _downloadAndValidate (Constraints I, O, P) ──────────────────────────────

local dl_dir = "/tmp/cloud_prefetch_spec_dl_" .. tostring(os.time())
os.execute("rm -rf " .. dl_dir)  -- ensure makePath's mkdir -p is exercised

local fake_plugin = { state_dir = dl_dir .. "/" }
local fake_server = { url = "https://example.invalid/dav" }

do
    -- Happy path: provider "downloads" valid JSON to whatever tmp_path
    -- _downloadAndValidate asked for.
    local fake_provider = {
        downloadFile = function(url, local_path)
            local f = io.open(local_path, "wb")
            f:write('{"entries":{}}')
            f:close()
            return 200
        end,
    }
    local ok = PluginSync._downloadAndValidate(
        fake_plugin, fake_provider, fake_server, "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "progress")
    h.assert_true(ok, "happy-path download+validate succeeds")
    local final_path = dl_dir .. "/cloud_staging/prefetch/syncery-progress-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC.json"
    local f = io.open(final_path, "rb")
    h.assert_true(f ~= nil, "final file exists after successful download")
    if f then f:close() end
end

do
    -- Non-200 response: no file should exist anywhere.
    local fake_provider = {
        downloadFile = function(url, local_path)
            return 404
        end,
    }
    local ok = PluginSync._downloadAndValidate(
        fake_plugin, fake_provider, fake_server, "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "progress")
    h.assert_false(ok, "non-200 response rejected")
    local final_path = dl_dir .. "/cloud_staging/prefetch/syncery-progress-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD.json"
    h.assert_true(io.open(final_path) == nil,
        "no final file for a failed download")
    h.assert_true(io.open(final_path .. ".tmp") == nil,
        "no lingering temp file for a failed download")
end

os.execute("rm -rf " .. dl_dir)

-- ── _moveOrCopyDelete (Constraint C) ────────────────────────────────────────

local mv_dir = "/tmp/cloud_prefetch_spec_mv_" .. tostring(os.time())
os.execute("mkdir -p " .. mv_dir)

do
    -- Same-filesystem path: plain os.rename succeeds.
    local src = mv_dir .. "/src1.json"
    local dst = mv_dir .. "/dst1.json"
    local f = io.open(src, "wb"); f:write('{"x":1}'); f:close()
    local ok = PluginSync._moveOrCopyDelete(src, dst)
    h.assert_true(ok, "same-filesystem move succeeds")
    h.assert_true(io.open(src) == nil, "source removed after successful rename")
    local df = io.open(dst, "rb")
    h.assert_true(df ~= nil, "destination exists after move")
    if df then h.assert_equal(df:read("*a"), '{"x":1}', "destination content correct"); df:close() end
end

do
    -- Force os.rename to fail (simulating EXDEV) -- fallback path must
    -- write+verify+delete instead, never losing the source before the
    -- destination write is confirmed.
    local src = mv_dir .. "/src2.json"
    local dst = mv_dir .. "/dst2.json"
    local f = io.open(src, "wb"); f:write('{"y":2}'); f:close()

    local real_rename = os.rename
    os.rename = function() return nil, "Invalid cross-device link" end
    local ok = PluginSync._moveOrCopyDelete(src, dst)
    os.rename = real_rename

    h.assert_true(ok, "EXDEV-simulated fallback still succeeds")
    h.assert_true(io.open(src) == nil, "source removed after fallback completes")
    local df = io.open(dst, "rb")
    h.assert_true(df ~= nil, "destination exists after fallback")
    if df then h.assert_equal(df:read("*a"), '{"y":2}', "fallback destination content correct"); df:close() end
end

do
    -- Missing source: neither path should raise.
    local ok = PluginSync._moveOrCopyDelete(mv_dir .. "/does-not-exist.json", mv_dir .. "/dst3.json")
    h.assert_false(ok, "missing source reported as failure, not a crash")
end

os.execute("rm -rf " .. mv_dir)

-- ── apply_staged_prefetch (Constraints M, G, toggle-respecting) ─────────────

local ap_dir = "/tmp/cloud_prefetch_spec_ap_" .. tostring(os.time())
os.execute("rm -rf " .. ap_dir)
os.execute("mkdir -p " .. ap_dir .. "/cloud_staging/prefetch")

local function make_fake_plugin(overrides)
    local p = {
        state_dir        = ap_dir .. "/",
        sync_progress     = true,
        sync_annotations  = true,
        sync_metadata     = true,
        sync_render_settings = true,
        _isFileTypeSynced = function(_self, _book_file) return true end,
    }
    for k, v in pairs(overrides or {}) do p[k] = v end
    return p
end

local book_id = "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
local fake_book_file = ap_dir .. "/fake_book.epub"
do  -- a real, existing (empty) book file so path-building has something to work with
    local f = io.open(fake_book_file, "wb"); f:write("x"); f:close()
end

local function stage(kind, content)
    local path = ap_dir .. "/cloud_staging/prefetch/syncery-" .. kind .. "-" .. book_id .. ".json"
    local f = io.open(path, "wb"); f:write(content); f:close()
    return path
end

do
    -- Unsafe book_id: defensive check must skip entirely, no crash.
    local plugin = make_fake_plugin()
    local ok = pcall(PluginSync.apply_staged_prefetch, plugin, "../../../etc/passwd", fake_book_file)
    h.assert_true(ok, "unsafe book_id does not raise")
end

do
    -- File type not synced: must return immediately, nothing moved.
    stage("progress", '{"entries":{}}')
    local plugin = make_fake_plugin({
        _isFileTypeSynced = function() return false end,
    })
    local ok = pcall(PluginSync.apply_staged_prefetch, plugin, book_id, fake_book_file)
    h.assert_true(ok, "unsynced file type does not raise")
    local still_staged = io.open(ap_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json")
    h.assert_true(still_staged ~= nil, "staged file left untouched when file type is not synced")
    if still_staged then still_staged:close() end
end

do
    -- sync_progress = false: progress must stay staged, not moved.
    os.execute("rm -f " .. ap_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json")
    stage("progress", '{"entries":{}}')
    local plugin = make_fake_plugin({ sync_progress = false })
    local ok = pcall(PluginSync.apply_staged_prefetch, plugin, book_id, fake_book_file)
    h.assert_true(ok, "sync_progress=false path does not raise")
    local still_staged = io.open(ap_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json")
    h.assert_true(still_staged ~= nil, "progress stays staged when sync_progress is false")
    if still_staged then still_staged:close() end
end

os.execute("rm -rf " .. ap_dir)

-- ── _prefetchViaFallback (Constraints S, T -- corrected during implementation) ──

do
    local calls = {}
    local fake_orch = {
        pull_book = function(_self, sentinel, opts, callback)
            table.insert(calls, { sentinel = sentinel, payload = opts.payload })
            if callback then callback({}) end
        end,
    }
    -- pull_book is called as a method (orch:pull_book(...)); Lua's colon
    -- syntax passes fake_orch itself as the first arg, so mimic that here.
    PluginSync._prefetchViaFallback({ state_dir = "/tmp/" }, fake_orch,
        "1234567890ABCDEF1234567890ABCDEF", "progress")

    h.assert_equal(#calls, 1, "exactly one pull_book call for one kind")
    h.assert_equal(calls[1].payload.kind, "prefetch_progress",
        "progress kind maps to prefetch_progress pull kind")
    h.assert_equal(calls[1].payload.book_id, "1234567890ABCDEF1234567890ABCDEF",
        "book_id passed through unchanged")
    h.assert_true(type(calls[1].payload.content) == "string"
        and calls[1].payload.content ~= "",
        "a non-empty bootstrap envelope string is provided as content")

    PluginSync._prefetchViaFallback({ state_dir = "/tmp/" }, fake_orch,
        "1234567890ABCDEF1234567890ABCDEF", "annotations")
    h.assert_equal(calls[2].payload.kind, "prefetch_annotations",
        "annotations kind maps to prefetch_annotations pull kind")
end


-- ── enumerate_prefetch_staging / extract_title_hint (section 4.4) ──────────

local ui_dir = "/tmp/cloud_prefetch_spec_ui_" .. tostring(os.time())
os.execute("rm -rf " .. ui_dir)
os.execute("mkdir -p " .. ui_dir .. "/cloud_staging/prefetch")

do
    -- Missing folder entirely: must return {} without raising.
    local plugin = { state_dir = "/tmp/definitely-does-not-exist-" .. tostring(os.time()) .. "/" }
    local by_book = PluginSync.enumerate_prefetch_staging(plugin)
    h.assert_deep_equal(by_book, {}, "missing prefetch folder yields an empty table, not an error")
end

do
    local plugin = { state_dir = ui_dir .. "/" }
    local id1 = "1111111111111111111111111111111A"
    local id2 = "2222222222222222222222222222222B"

    local function write(name, content)
        local f = io.open(ui_dir .. "/cloud_staging/prefetch/" .. name, "wb")
        f:write(content); f:close()
    end
    write("syncery-progress-" .. id1 .. ".json",
        '{"entries":{"D1":{"file":"/mnt/us/Books/BG/Some Author - A Title.epub","percent":0.3}}}')
    write("syncery-annotations-" .. id1 .. ".json", '{"annotations":{}}')
    write("syncery-progress-" .. id2 .. ".json", '{"entries":{}}')
    write("syncery-progress-not$safe.json", '{"entries":{}}')  -- unsafe (regex), must be ignored
    write("not-a-syncery-file.txt", "junk")                             -- non-matching, ignored

    local by_book = PluginSync.enumerate_prefetch_staging(plugin)
    h.assert_true(by_book[id1] ~= nil, "book 1 (both kinds) grouped")
    h.assert_true(by_book[id1].progress ~= nil, "book 1 progress path present")
    h.assert_true(by_book[id1].annotations ~= nil, "book 1 annotations path present")
    h.assert_true(by_book[id2] ~= nil, "book 2 (progress only) grouped")
    h.assert_nil(by_book[id2].annotations, "book 2 has no annotations entry")

    local unsafe_count = 0
    for id in pairs(by_book) do
        if id:match("[^%w%-_]") then unsafe_count = unsafe_count + 1 end
    end
    h.assert_equal(unsafe_count, 0, "unsafe book_id never entered the enumerated table")

    local title = PluginSync.extract_title_hint(by_book[id1].progress)
    h.assert_equal(title, "Some Author - A Title",
        "title extracted from entries[*].file basename, extension stripped")

    local no_title = PluginSync.extract_title_hint(by_book[id2].progress)
    h.assert_nil(no_title, "no \"file\" field present -> nil, not an error")

    h.assert_nil(PluginSync.extract_title_hint(nil), "nil path -> nil, no raise")
    h.assert_nil(PluginSync.extract_title_hint(ui_dir .. "/does-not-exist.json"),
        "missing file -> nil, no raise")
end

os.execute("rm -rf " .. ui_dir)

h.report("cloud_prefetch_spec")
