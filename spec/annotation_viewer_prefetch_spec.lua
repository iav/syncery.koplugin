-- =============================================================================
-- spec/annotation_viewer_prefetch_spec.lua
-- =============================================================================
--
-- Verifies the specific claim docs/CLOUD_PREFETCH_DESIGN.md section 4.4
-- makes about the Annotation Browser: ViewerSource.notes_for_book already
-- accepts book.annotations_path directly and tolerates book.path == nil,
-- confirmed by running the REAL notes_for_book against prefetch-shaped
-- data, not just asserted from reading the source.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_annotation_viewer_prefetch_spec_" .. tostring(os.time()))

local ViewerSource = require("syncery_ui/annotation_viewer/viewer_source")
local PluginSync = require("syncery_transports/plugin_sync")

local test_dir = "/tmp/avp_spec_" .. tostring(os.time())
os.execute("rm -rf " .. test_dir)
os.execute("mkdir -p " .. test_dir .. "/cloud_staging/prefetch")

local book_id = "D53AC9A412E14EC8A349E04F1DFFC6EE"
local device_id = "SOME_PEER_DEVICE_ID_0000000000"

local annotations_content = string.format(
    '{"annotations":{"/body/p[1].0||/body/p[1].10":{"chapter":"Chapter One",' ..
    '"color":"yellow","datetime":"2026-07-11 23:51:02","device_id":"%s",' ..
    '"device_label":"SomeDevice","drawer":"lighten","page":"/body/p[1].0",' ..
    '"pageno":1,"pos0":"/body/p[1].0","pos1":"/body/p[1].10",' ..
    '"text":"a highlighted passage"}},"schema_version":1}',
    device_id)

do
    local f = io.open(test_dir .. "/cloud_staging/prefetch/syncery-annotations-" .. book_id .. ".json", "wb")
    f:write(annotations_content)
    f:close()
end

local plugin = { state_dir = test_dir .. "/" }
local by_book = PluginSync.enumerate_prefetch_staging(plugin)

h.assert_true(by_book[book_id] ~= nil, "prefetch-staged book is enumerated")
h.assert_true(by_book[book_id].annotations ~= nil, "annotations path present")

-- Exactly the shape the viewer_lifted.lua integration builds: no path, an
-- annotations_path, and a title.
local book = {
    path             = nil,
    annotations_path = by_book[book_id].annotations,
    title            = "A Test Book With Highlights",
}

local ok_call, notes = pcall(ViewerSource.notes_for_book, book)
h.assert_true(ok_call, "notes_for_book does not raise for a path-less book")
h.assert_true(type(notes) == "table", "notes_for_book returns a table")
h.assert_equal(#notes, 1, "the one alive annotation is returned")
if notes[1] then
    h.assert_equal(notes[1].highlighted_text, "a highlighted passage",
        "the real highlighted text is present")
    h.assert_equal(notes[1].book_title, "A Test Book With Highlights",
        "book_title carries the extracted/passed-in title, not nil")
    h.assert_nil(notes[1].book_path,
        "book_path is genuinely nil, not a stub artifact -- confirms the "
        .. "path-less shape is truly tolerated, not accidentally working")
end

os.execute("rm -rf " .. test_dir)

h.report("annotation_viewer_prefetch_spec")
