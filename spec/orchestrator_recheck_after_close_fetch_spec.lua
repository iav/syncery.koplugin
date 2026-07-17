-- =============================================================================
-- spec/orchestrator_recheck_after_close_fetch_spec.lua
-- =============================================================================
--
-- Regression test for the underlying SyncOrchestrator behaviour that
-- Teardown.flush's Step 3.5 (syncery_lifecycle/teardown.lua) depends on:
-- re-running SyncOrchestrator.sync_book_with_providers AFTER canonical
-- has been refreshed (by Step 3's cloud fetch) must produce a DIFFERENT,
-- fresher result than an earlier call made before that refresh.
--
-- This complements, rather than duplicates, spec/lifecycle_teardown_spec.lua's
-- own Step 3.5 test: that one stubs plugin:_syncBookViaOrchestrator with
-- canned results to verify TEARDOWN'S OWN WIRING (called twice, distinct
-- trigger labels, the stash gets overwritten). THIS spec instead drives the
-- REAL SyncOrchestrator.sync_book_with_providers (real Merge/Tombstones
-- logic, fake state_store/doc_settings_bridge providers only), proving the
-- ORCHESTRATOR ITSELF correctly reflects a canonical change across two
-- calls -- a property Step 3.5's wiring assumes but does not itself
-- exercise, since its own test doubles the orchestrator out entirely.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local Orchestrator = require("syncery_ann/sync_orchestrator")

-- ----------------------------------------------------------------------------
-- Fakes (same shape as spec/sync_orchestrator_spec.lua's make_fakes, kept
-- self-contained here so this spec stands alone).
-- ----------------------------------------------------------------------------

local function make_fake_ui()
    return h.make_fake_ui({})
end

local function default_options()
    return {
        device_id    = "device-B",
        device_label = "Device B",
        toggles = {
            annotations     = true,
            highlights      = true,
            notes           = true,
            bookmarks       = true,
            metadata        = true,
            status          = true,
            rating          = true,
            collections     = true,
            summary         = true,
            custom          = true,
            handmade        = true,
            render_settings = false,
        },
        tombstone_ttl_days = 30,
    }
end

local function make_fakes(initial)
    initial = initial or {}
    local fakes = {
        shared_state    = initial.shared_state    or {
            schema_version = 1, annotations = {}, metadata = {}, render_settings = {},
        },
        last_sync_state = initial.last_sync_state or {
            schema_version = 1, annotations = {}, metadata = {}, render_settings = {},
        },
        doc_settings_map = initial.doc_settings_map or {},
        merged_applied   = nil,
        calls            = {},
    }
    local function record(method, args) table.insert(fakes.calls, { method = method, args = args }) end

    fakes.state_store = {
        load_shared     = function(_p) record("load_shared", {}); return fakes.shared_state, "ok" end,
        load_last_sync  = function(_p) record("load_last_sync", {}); return fakes.last_sync_state, "ok" end,
        save_shared     = function(_p, state, did, dl)
            record("save_shared", { state = state })
            fakes.shared_state = state
            return true
        end,
        save_last_sync  = function(_p, state)
            record("save_last_sync", { state = state })
            fakes.last_sync_state = state
            return true
        end,
    }
    fakes.doc_settings_bridge = {
        read_annotations_as_map = function(_ui)
            record("read_annotations_as_map", {})
            local copy = {}
            for k, v in pairs(fakes.doc_settings_map) do copy[k] = v end
            return copy, 0
        end,
        apply_and_refresh = function(_ui, state_map, options)
            record("apply_and_refresh", {})
            fakes.merged_applied = state_map
            return true, 0
        end,
    }
    fakes.metadata_bridge = {
        read_from_ui       = function() record("metadata.read_from_ui", {}); return {} end,
        apply_from_remote  = function() return false, {} end,
        merge              = function(a, b) return a or b or {} end,
        three_way          = function(l, r, _a) return l or r or {} end,
        make_toggles_from_plugin = function(_) return {} end,
    }
    fakes.render_settings_bridge = {
        read_from_ui       = function() return {} end,
        apply_from_remote  = function() return false end,
        merge              = function(a, b) return a or b or {} end,
        make_toggles_from_plugin = function(_) return {} end,
    }
    fakes.conflict_resolver = {
        resolve_all = function(_p) return 0, 0, nil end,
    }
    fakes.merge      = require("syncery_ann/merge")
    fakes.tombstones = require("syncery_ann/tombstones")
    return fakes
end


-- ----------------------------------------------------------------------------
-- THE regression test.
-- ----------------------------------------------------------------------------

do
    local ANN_KEY = "/body/DocFragment[1]/body/p[1]/text().0||/body/DocFragment[1]/body/p[1]/text().50"

    -- Device B already delivered device A's ORIGINAL (alive) annotation on
    -- a PREVIOUS close -- so it's already in the live doc_settings list
    -- AND already materialized into last_sync (matching a device that has
    -- been through at least one prior successful close+reopen cycle for
    -- this book, exactly as Group A's real-device data showed).
    local alive_entry = {
        text = "device A's original highlight", chapter = "Ch1", page = 1, pageno = 1,
        pos0 = ANN_KEY:match("^(.-)||"), pos1 = ANN_KEY:match("||(.*)$"),
        drawer = "lighten", color = "yellow",
        device_id = "device-A", device_label = "Device A",
        datetime = "2026-07-17 10:00:00", datetime_updated = "2026-07-17 10:00:00",
    }

    local shared_initial = {
        schema_version = 1,
        annotations = { [ANN_KEY] = alive_entry },
        metadata = {}, render_settings = {},
    }
    local fakes = make_fakes({
        shared_state     = shared_initial,
        last_sync_state  = shared_initial,   -- already materialized from a prior close
        doc_settings_map = { [ANN_KEY] = alive_entry },  -- already delivered, live in the UI
    })

    -- ── Step 2's own call (teardown.lua): canonical (shared_state) still
    -- shows the annotation alive -- device A's deletion has not been
    -- fetched into it yet at this point in the close sequence.
    local result1 = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", default_options(), fakes)

    h.assert_true(result1.ok, "Step 2's own call succeeds")
    local alive_after_step2 = 0
    for _, entry in pairs(result1.delivery_annotations or {}) do
        if not entry.deleted then alive_after_step2 = alive_after_step2 + 1 end
    end
    h.assert_equal(alive_after_step2, 1,
        "sanity: at this point (before Step 3's cloud fetch runs) the "
        .. "annotation is still alive -- device A's deletion has not "
        .. "reached canonical yet")

    -- ── Simulate Step 3: a cloud fetch (do_cloud_upload/pushOpenedBooks,
    -- entirely independent of this orchestrator call) lands DURING this
    -- same close, pulling in device A's tombstone and updating canonical.
    -- This mutation stands in for what the REAL cloud transport layer
    -- would have written to the shared canonical file.
    local tombstoned_entry = {}
    for k, v in pairs(alive_entry) do tombstoned_entry[k] = v end
    tombstoned_entry.deleted = true
    tombstoned_entry.datetime_updated = "2026-07-17 10:05:00"  -- newer than the original

    fakes.shared_state = {
        schema_version = 1,
        annotations = { [ANN_KEY] = tombstoned_entry },
        metadata = {}, render_settings = {},
    }

    -- ── Step 3.5's own call (teardown.lua): re-run the SAME orchestrator
    -- call, now that canonical has been refreshed by Step 3's cloud fetch.
    local result2 = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", default_options(), fakes)

    h.assert_true(result2.ok, "Step 3.5's re-run succeeds")
    local alive_after_step35 = 0
    local saw_tombstone = false
    for _, entry in pairs(result2.delivery_annotations or {}) do
        if entry.deleted then saw_tombstone = true
        else alive_after_step35 = alive_after_step35 + 1 end
    end
    h.assert_equal(alive_after_step35, 0,
        "REGRESSION GUARD: after Step 3's cloud fetch refreshes canonical, "
        .. "Step 3.5's re-run of the SAME orchestrator call now correctly "
        .. "computes ZERO alive annotations -- catching device A's "
        .. "deletion within THIS SAME close, instead of waiting for the "
        .. "next session. If this ever fails, either the orchestrator "
        .. "stopped reflecting canonical changes on re-invocation, or "
        .. "something cached a stale result across the two calls -- both "
        .. "would silently defeat Step 3.5's whole purpose")
    h.assert_true(saw_tombstone,
        "REGRESSION GUARD: the tombstone is present in the re-run's "
        .. "delivery map, ready to be written to doc_settings by "
        .. "stage_pending_at_close via the SAME code path Step 2 already "
        .. "uses today")
end


print("orchestrator_recheck_after_close_fetch_spec: all assertions passed")
