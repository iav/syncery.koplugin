-- =============================================================================
-- spec/progress_browser_prefetch_spec.lua
-- =============================================================================
--
-- Verifies the specific claim docs/CLOUD_PREFETCH_DESIGN.md section 4.4
-- makes about Progress Browser: aggregate.lua's own my_percent==nil ->
-- state="behind" branch already handles a prefetch-pending book (no local
-- entry, peer entries exist) as a first-class case, confirmed by running
-- the REAL Aggregate.aggregate_book against prefetch-shaped data -- not
-- just asserted from reading the source.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_browser_prefetch_spec_" .. tostring(os.time()))

local Aggregate = require("syncery_ui/progress_browser/aggregate")
local PluginSync = require("syncery_transports/plugin_sync")

local test_dir = "/tmp/pbp_spec_" .. tostring(os.time())
os.execute("rm -rf " .. test_dir)
os.execute("mkdir -p " .. test_dir .. "/cloud_staging/prefetch")

local this_device = "THIS_DEVICE_ID_0000000000000000"
local peer_device  = "PEER_DEVICE_ID_0000000000000000"
local book_id      = "9AFFCFE4A34647A08208E4D610DF10C3"

local progress_content = string.format(
    '{"entries":{"%s":{"device_id":"%s","file":"/mnt/us/Books/A Test Book.epub",' ..
    '"percent":0.45,"timestamp":%d}},"schema_version":1}',
    peer_device, peer_device, os.time())

do
    local f = io.open(test_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json", "wb")
    f:write(progress_content)
    f:close()
end

local plugin = { state_dir = test_dir .. "/" }
local by_book = PluginSync.enumerate_prefetch_staging(plugin)

h.assert_true(by_book[book_id] ~= nil, "prefetch-staged book is enumerated")
h.assert_true(by_book[book_id].progress ~= nil, "progress path present for the staged book")

local title = PluginSync.extract_title_hint(by_book[book_id].progress)
h.assert_equal(title, "A Test Book", "title extracted for the Progress Browser row")

-- Simulate exactly what ProgressBrowser.show does with this entry: load the
-- shared state from progress_path (here, directly -- no conflict resolver
-- needed for this narrow check) and run it through the REAL aggregate_book.
local ProgressStateStore = require("syncery_progress/state_store")
local state = ProgressStateStore.load_shared_from_path(by_book[book_id].progress)
local agg = Aggregate.aggregate_book(state.entries, this_device, {})

h.assert_nil(agg.my_percent,
    "this device has no entry -- my_percent is genuinely nil, not a stub artifact")
h.assert_equal(agg.state, "behind",
    "aggregate_book classifies a peer-only entry as behind, exactly as the design claims")

os.execute("rm -rf " .. test_dir)

h.report("progress_browser_prefetch_spec")
