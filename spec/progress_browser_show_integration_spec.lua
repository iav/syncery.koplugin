-- =============================================================================
-- spec/progress_browser_show_integration_spec.lua
-- =============================================================================
--
-- Integration test for the ACTUAL wiring inside ProgressBrowser.show()
-- (docs/CLOUD_PREFETCH_DESIGN.md, section 4.4) -- not just the underlying
-- aggregate.lua claim (that is progress_browser_prefetch_spec.lua's job).
-- This calls the real .show(plugin) with stubbed UI widgets and inspects
-- the item_table actually built, so a regression in the merge condition
-- itself (not just in aggregate.lua) is caught.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_browser_show_spec_" .. tostring(os.time()))

local test_dir = "/tmp/pbs_spec_" .. tostring(os.time())
os.execute("rm -rf " .. test_dir)
os.execute("mkdir -p " .. test_dir .. "/cloud_staging/prefetch")

-- Stub every UI dependency progress_browser/init.lua requires at load time.
package.loaded["ui/uimanager"] = { show = function() end, close = function() end }
local last_menu
package.loaded["ui/widget/menu"] = {
    new = function(_, a) last_menu = a; return a or {} end,
}
package.loaded["ui/widget/buttondialog"] = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/infomessage"]  = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/confirmbox"]   = { new = function(_, a) return a or {} end }
package.loaded["device"] = {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
}
package.loaded["syncery_ui/action_bar"] = { new = function() return {} end }
package.loaded["syncery_ui/status_ui/init"] = {}
-- Stub the real filesystem scan out entirely -- this test's target is the
-- prefetch MERGE, not ProgressEnum's own scanning machinery (covered by
-- progress_enum_spec.lua already).
package.loaded["syncery_ui/progress_browser/progress_enum"] = {
    enumerate = function() return {} end,
}

-- Force a fresh load of progress_browser/init.lua under these stubs, and
-- point PluginSync.enumerate_prefetch_staging at our real temp fixtures
-- via a real plugin.state_dir (Util.state_dir is not used here --
-- ProgressBrowser.show takes plugin directly, so state_dir is set on the
-- fake plugin passed in below).
package.loaded["syncery_ui/progress_browser/init"] = nil
local ProgressBrowser = require("syncery_ui/progress_browser/init")

local book_id = "1111111111111111111111111111111C"
local peer_device = "PEER0000000000000000000000000000"
local progress_content = string.format(
    '{"entries":{"%s":{"device_id":"%s","file":"/mnt/us/Books/Only On Peer.epub",' ..
    '"percent":0.2,"timestamp":%d}},"schema_version":1}',
    peer_device, peer_device, os.time())

local function write_progress()
    local f = io.open(test_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json", "wb")
    f:write(progress_content)
    f:close()
end

local plugin = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }

do
    write_progress()
    last_menu = nil
    ProgressBrowser.show(plugin)
    h.assert_true(last_menu ~= nil, "Menu:new was called")
    h.assert_true(type(last_menu.item_table) == "table", "item_table is a table")
    h.assert_equal(#last_menu.item_table, 1,
        "the prefetch-pending, peer-only book produces exactly one row")
    h.assert_true(last_menu.item_table[1].text:find("Only On Peer", 1, true) ~= nil,
        "the row's text includes the title extracted from the peer's file field")
end

os.execute("rm -rf " .. test_dir)

h.report("progress_browser_show_integration_spec")
