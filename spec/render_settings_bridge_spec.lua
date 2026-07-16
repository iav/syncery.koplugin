-- =============================================================================
-- spec/render_settings_bridge_spec.lua
-- =============================================================================
--
-- Tests for syncery_ann/render_settings_bridge.lua (per-field).
--
-- Load-bearing guards:
--   * KEY CORRECTNESS — reads/writes the exact KOReader keys (copt_* +
--     top-level font_face), never the bare names (the phantom-key class;
--     lesson #30). A decoy bare key proves the real key is used.
--   * VALUE UNWRAP — apply writes the plain value KOReader expects, never
--     the per-field {value, datetime_updated} wrapper.
--   * TIMESTAMP STABILITY — an unchanged field keeps its timestamp across
--     reads (no spurious re-bump). Byte-identity across devices depends on
--     this: the same value must never earn a new timestamp on one device.
--   * PER-FIELD MERGE — newer datetime_updated wins per key, a key on only
--     one side is preserved, and fields from different devices ACCUMULATE.
--
-- doc_settings keys (verified against KOReader source):
--   font_face -> "font_face" (ReaderFont top-level)
--   font_size -> "copt_font_size" ; line_spacing -> "copt_line_spacing"
--   font_weight -> "copt_font_base_weight"
--   margins -> "copt_h_page_margins" + "copt_t_page_margin" + "copt_b_page_margin"
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local RenderBridge = require("syncery_ann/render_settings_bridge")


-- A toggles map with master + the named fields on; everything else off.
local function toggles(...)
    local t = {
        master = false, font_face = false, font_size = false,
        line_spacing = false, font_weight = false, margins = false,
    }
    for _, name in ipairs({ ... }) do t[name] = true end
    return t
end

-- Build a per-field entry the way a remote block would carry it.
local function entry(value, datetime)
    return { value = value, datetime_updated = datetime }
end


-- ----------------------------------------------------------------------------
-- make_toggles_from_plugin — opt-in mapping (== true)
-- ----------------------------------------------------------------------------


do
    local t = RenderBridge.make_toggles_from_plugin({
        sync_render_settings = true, sync_font_face = true, sync_font_size = true,
        sync_line_spacing = true, sync_font_weight = true, sync_margins = true,
    })
    h.assert_true(t.master and t.font_face and t.font_size and t.line_spacing
        and t.font_weight and t.margins, "make_toggles: all true -> all on")
end

do
    local t = RenderBridge.make_toggles_from_plugin({
        sync_render_settings = true, sync_font_size = true,
    })
    h.assert_true(t.master and t.font_size, "make_toggles: explicit fields on")
    h.assert_false(t.margins or t.font_face, "make_toggles: unset fields off (opt-in)")
end

do
    local t = RenderBridge.make_toggles_from_plugin({ sync_render_settings = false })
    h.assert_false(t.master, "make_toggles: master off when flag false")
end

do
    local t = RenderBridge.make_toggles_from_plugin(nil)
    h.assert_false(t.master or t.font_face or t.font_size or t.line_spacing
        or t.font_weight or t.margins, "make_toggles(nil): fully off")
end


-- ----------------------------------------------------------------------------
-- read_from_ui — gates
-- ----------------------------------------------------------------------------


do
    local ui = h.make_fake_ui({ settings = { copt_font_size = 22 } })
    h.assert_nil(RenderBridge.read_from_ui(ui, toggles("font_size")),
        "read: master off -> nil")
end

do
    local ui = h.make_fake_ui({ paging = true, settings = { copt_font_size = 22 } })
    h.assert_nil(RenderBridge.read_from_ui(ui, toggles("master", "font_size")),
        "read: paging document -> nil")
end

do
    local ui = h.make_fake_ui({ settings = {} })
    h.assert_nil(RenderBridge.read_from_ui(ui, toggles("master", "font_size")),
        "read: nothing set on device -> nil")
end


-- ----------------------------------------------------------------------------
-- read_from_ui — KEY CORRECTNESS (phantom-key guard) + per-field entries
-- ----------------------------------------------------------------------------


do
    -- font_size must come from "copt_font_size", NOT bare "font_size".
    local ui = h.make_fake_ui({ settings = { copt_font_size = 22, font_size = 999 } })
    local block = RenderBridge.read_from_ui(ui, toggles("master", "font_size"))
    h.assert_true(type(block.copt_font_size) == "table", "read: field is a per-field entry")
    h.assert_equal(block.copt_font_size.value, 22,
        "read: font_size reads the REAL key copt_font_size")
    h.assert_true(block.copt_font_size.datetime_updated ~= nil,
        "read: per-field entry carries datetime_updated")
    h.assert_nil(block.font_size, "read: bare 'font_size' is NOT read (phantom guard)")
end

do
    local ui = h.make_fake_ui({ settings = { font_face = "Bitter" } })
    local block = RenderBridge.read_from_ui(ui, toggles("master", "font_face"))
    h.assert_equal(block.font_face.value, "Bitter",
        "read: font_face reads the top-level 'font_face' key")
end

do
    local ui = h.make_fake_ui({ settings = { copt_line_spacing = 100, copt_font_base_weight = 0.5 } })
    local block = RenderBridge.read_from_ui(ui, toggles("master", "line_spacing", "font_weight"))
    h.assert_equal(block.copt_line_spacing.value, 100, "read: line_spacing -> copt_line_spacing")
    h.assert_equal(block.copt_font_base_weight.value, 0.5, "read: font_weight -> copt_font_base_weight")
end


-- ----------------------------------------------------------------------------
-- read_from_ui — per-field gating + margins grouping
-- ----------------------------------------------------------------------------


do
    local ui = h.make_fake_ui({ settings = { copt_font_size = 22, copt_line_spacing = 100 } })
    local block = RenderBridge.read_from_ui(ui, toggles("master", "font_size"))
    h.assert_equal(block.copt_font_size.value, 22, "read: enabled field present")
    h.assert_nil(block.copt_line_spacing, "read: disabled field absent (per-field gating)")
end

do
    local ui = h.make_fake_ui({ settings = {
        copt_h_page_margins = 15, copt_t_page_margin = 10, copt_b_page_margin = 10,
    } })
    local block = RenderBridge.read_from_ui(ui, toggles("master", "margins"))
    h.assert_equal(block.copt_h_page_margins.value, 15, "read margins: h present")
    h.assert_equal(block.copt_t_page_margin.value, 10, "read margins: t present")
    h.assert_equal(block.copt_b_page_margin.value, 10, "read margins: b present")
end


-- ----------------------------------------------------------------------------
-- read_from_ui — TIMESTAMP STABILITY (byte-identity guard)
-- ----------------------------------------------------------------------------


do
    -- Pre-seed the cached state with an OLD per-field timestamp.  An
    -- unchanged value (fingerprint matches) must CARRY IT FORWARD, not
    -- regenerate now() — this is what keeps the timestamp identical across
    -- devices (byte-identity).  Breaking the fingerprint compare (always
    -- re-bump) would replace it with today's now() and fail here.
    local ui = h.make_fake_ui({ settings = {
        copt_font_size = 22,
        syncery_render_state = {
            fields = {
                copt_font_size = { value = "22", datetime_updated = "2020-01-01 00:00:00" },
            },
        },
    } })
    local block = RenderBridge.read_from_ui(ui, toggles("master", "font_size"))
    h.assert_equal(block.copt_font_size.datetime_updated, "2020-01-01 00:00:00",
        "read: unchanged value carries forward the cached timestamp (no spurious re-bump)")
end

do
    -- Changing one field does not disturb a sibling's timestamp (per-field).
    local ui = h.make_fake_ui({ settings = { copt_font_size = 22, copt_line_spacing = 100 } })
    local b1 = RenderBridge.read_from_ui(ui, toggles("master", "font_size", "line_spacing"))
    local space_ts = b1.copt_line_spacing.datetime_updated
    ui._settings.copt_font_size = 24  -- change only font_size
    local b2 = RenderBridge.read_from_ui(ui, toggles("master", "font_size", "line_spacing"))
    h.assert_equal(b2.copt_font_size.value, 24, "read: changed field reflects the new value")
    h.assert_equal(b2.copt_line_spacing.datetime_updated, space_ts,
        "read: unchanged sibling keeps its timestamp (per-field change detection)")
end

do
    -- copt_h_page_margins is a POSITIONAL {left, right} table.  An L/R swap is a
    -- real change and must travel: the fingerprint preserves order, so an
    -- identical value carries the cached timestamp forward (stable) while a swap
    -- gets a fresh one.  A SORTED fingerprint would collapse {10,20} and {20,10}
    -- to one string and silently drop the swap.  Pre-seed an OLD timestamp so
    -- the post-swap now() is reliably distinguishable.
    local ui = h.make_fake_ui({ settings = {
        copt_h_page_margins = { 10, 20 },
        syncery_render_state = {
            fields = {
                copt_h_page_margins = {
                    value            = RenderBridge._fingerprint_value({ 10, 20 }),
                    datetime_updated = "2020-01-01 00:00:00",
                },
            },
        },
    } })

    local b_same = RenderBridge.read_from_ui(ui, toggles("master", "margins"))
    h.assert_equal(b_same.copt_h_page_margins.datetime_updated, "2020-01-01 00:00:00",
        "read: identical {left,right} margins carry the cached timestamp (stable, no re-bump)")

    ui._settings.copt_h_page_margins = { 20, 10 }  -- swap left <-> right
    local b_swap = RenderBridge.read_from_ui(ui, toggles("master", "margins"))
    h.assert_true(b_swap.copt_h_page_margins.datetime_updated ~= "2020-01-01 00:00:00",
        "read: an L/R margin swap is detected as a change (positional fingerprint), not dropped")
end


-- ----------------------------------------------------------------------------
-- merge — per-field newer-wins, accumulation, tie-break
-- ----------------------------------------------------------------------------


do
    -- Newer datetime wins per key.
    local a = { copt_font_size = entry(22, "2025-01-01 00:00:00") }
    local b = { copt_font_size = entry(28, "2025-06-01 00:00:00") }
    local m = RenderBridge.merge(a, b)
    h.assert_equal(m.copt_font_size.value, 28, "merge: newer entry wins per key")
end

do
    -- A key present on only one side is preserved.
    local a = { copt_font_size = entry(22, "2025-01-01 00:00:00") }
    local b = { copt_line_spacing = entry(100, "2025-01-01 00:00:00") }
    local m = RenderBridge.merge(a, b)
    h.assert_equal(m.copt_font_size.value, 22, "merge: a-only key preserved")
    h.assert_equal(m.copt_line_spacing.value, 100, "merge: b-only key preserved")
end

do
    -- ACCUMULATION: font_size from one device + margins from another both survive.
    local dev_a = { copt_font_size = entry(24, "2025-06-02 00:00:00") }
    local dev_b = {
        copt_h_page_margins = entry(15, "2025-06-01 00:00:00"),
        copt_t_page_margin  = entry(10, "2025-06-01 00:00:00"),
        copt_b_page_margin  = entry(10, "2025-06-01 00:00:00"),
    }
    local m = RenderBridge.merge(dev_a, dev_b)
    h.assert_equal(m.copt_font_size.value, 24, "merge accumulation: device A font_size survives")
    h.assert_equal(m.copt_h_page_margins.value, 15, "merge accumulation: device B margins survive")
end

do
    -- Convergence: an exact-timestamp tie must resolve COMMUTATIVELY, so
    -- merge(local,remote) and merge(remote,local) -- the two devices' views --
    -- reach the SAME bytes.  (The old ">=" tie-break favoured argument A, so
    -- each device kept its OWN value and the shared file never converged ->
    -- Syncthing churn.)  This is the swapped-argument byte-identity proof.
    local a = { copt_font_size = entry(22, "2025-01-01 00:00:00") }
    local b = { copt_font_size = entry(28, "2025-01-01 00:00:00") }
    local ab = RenderBridge.merge(a, b)
    local ba = RenderBridge.merge(b, a)
    h.assert_equal(ab.copt_font_size.value, ba.copt_font_size.value,
        "merge: equal-timestamp tie is COMMUTATIVE (merge(a,b) == merge(b,a))")
    -- Deterministic winner by value fingerprint (device-independent): "22" < "28".
    h.assert_equal(ab.copt_font_size.value, 22,
        "merge: tie broken on value fingerprint (lower wins), not argument order")
end


-- ----------------------------------------------------------------------------
-- apply_from_remote — gates + KEY CORRECTNESS + VALUE UNWRAP
-- ----------------------------------------------------------------------------


do
    local ui = h.make_fake_ui({ settings = {} })
    local applied = RenderBridge.apply_from_remote(ui,
        { copt_font_size = entry(24, "2025-01-01 00:00:00") }, toggles("font_size"))
    h.assert_false(applied, "apply: master off -> false")
    h.assert_nil(ui._settings.copt_font_size, "apply: master off writes nothing")
end

do
    -- Explicit starting value (18), not nil: this test is about key
    -- correctness/unwrap/gating, not about the first-ever-sync nil case
    -- (that gets its own dedicated test below) -- an explicit prior
    -- value genuinely changing is what "applied" should mean here.
    local ui = h.make_fake_ui({ settings = { copt_font_size = 18 } })
    local applied = RenderBridge.apply_from_remote(ui,
        { copt_font_size = entry(24, "2025-01-01 00:00:00") },
        toggles("master", "font_size"))
    h.assert_true(applied, "apply: newer remote with field on -> applied")
    h.assert_equal(ui._settings.copt_font_size, 24,
        "apply: writes the REAL key copt_font_size, UNWRAPPED to the plain value")
    h.assert_true(type(ui._settings.copt_font_size) ~= "table",
        "apply: value is unwrapped (NOT the {value,datetime} table) -- KOReader needs the plain value")
    h.assert_nil(ui._settings.font_size, "apply: bare 'font_size' NOT written (phantom guard)")
end

do
    -- Field off: present in the block but not applied.
    local ui = h.make_fake_ui({ settings = {} })
    local applied = RenderBridge.apply_from_remote(ui,
        { copt_font_size = entry(24, "2025-01-01 00:00:00") },
        toggles("master", "line_spacing"))
    h.assert_false(applied, "apply: field off -> nothing applied")
    h.assert_nil(ui._settings.copt_font_size, "apply: disabled field not written")
end

-- ----------------------------------------------------------------------------
-- BUGFIX: first-ever cross-device
-- sync of a field THIS device never explicitly customized (doc_settings
-- has nothing for this book yet) must still WRITE the peer's value (so
-- the data is correctly recorded/synced going forward), but "applied"
-- must reflect whether something ACTUALLY changes for THIS device's
-- user -- compared against the LIVE effective value (a global
-- preference or KOReader's own hardcoded default -- see
-- _read_live_state, traced against frontend/configurable.lua and
-- frontend/apps/reader/modules/readerfont.lua), not merely "doc_settings
-- had nothing saved yet". Confirmed via real WebDAV data (part 1: two
-- genuinely different devices held IDENTICAL untouched-default values,
-- a false positive) and via a follow-up real-device test (part 2: a
-- deliberately different peer value, e.g. font_face=OpenDyslexic vs
-- this device's own default, on a book neither device had opened
-- before, correctly still triggers "applied").
-- ----------------------------------------------------------------------------

do
    -- Part 1: never customized, peer's value MATCHES this device's own
    -- live default (e.g. both fell back to the same built-in default) --
    -- nothing is visibly changing, must NOT report applied.
    local ui = h.make_fake_ui({
        settings     = {},                  -- doc_settings: never saved
        configurable = { font_size = 24 },  -- live default happens to match remote
    })
    local applied = RenderBridge.apply_from_remote(ui,
        { copt_font_size = entry(24, "2025-01-01 00:00:00") },
        toggles("master", "font_size"))
    h.assert_false(applied,
        "apply: never-customized field whose peer value MATCHES this "
        .. "device's own live default is NOT reported as applied -- "
        .. "nothing is visibly changing")
    h.assert_nil(ui._settings.copt_font_size,
        "apply: values already matched (live default == remote), so there "
        .. "is nothing to write -- doc_settings stays untouched, not a "
        .. "redundant explicit copy of what the live default already gives")
end

do
    -- Part 2 (the new capability): never customized, but peer's value
    -- GENUINELY DIFFERS from this device's own live default -- e.g. a
    -- peer deliberately set font_face=OpenDyslexic while this device's
    -- own live default is something else, on a book THIS device has
    -- never opened before. Must STILL report applied: a real,
    -- deliberate peer customization must not be silenced just because
    -- this device happens to be seeing the book for the first time.
    local ui = h.make_fake_ui({
        settings     = {},                       -- doc_settings: never saved
        configurable = { font_size = 16 },       -- live default DIFFERS from remote
    })
    local applied = RenderBridge.apply_from_remote(ui,
        { copt_font_size = entry(24, "2025-01-01 00:00:00") },
        toggles("master", "font_size"))
    h.assert_true(applied,
        "apply: never-customized field whose peer value DIFFERS from "
        .. "this device's own live default (16 vs 24) IS reported as "
        .. "applied, even though this book was never opened here before")
    h.assert_equal(ui._settings.copt_font_size, 24, "apply: value written as usual")
end

do
    -- The SAME field, but THIS device DOES have an explicit prior value
    -- in doc_settings: a genuine overwrite must still report "applied"
    -- normally -- unaffected by the live-state fallback (doc_settings
    -- wins outright when present, live state is only consulted when
    -- doc_settings has nothing).
    local ui = h.make_fake_ui({ settings = { copt_font_size = 18 } })
    local applied = RenderBridge.apply_from_remote(ui,
        { copt_font_size = entry(24, "2025-01-01 00:00:00") },
        toggles("master", "font_size"))
    h.assert_true(applied,
        "apply: an EXPLICIT prior value (18) genuinely overwritten by remote "
        .. "(24) still reports applied -- this device's user HAD something changing")
    h.assert_equal(ui._settings.copt_font_size, 24, "apply: value written as usual")
end

do
    -- font_face uses a DIFFERENT live-state object (ui.font.font_face,
    -- not ui.document.configurable) -- same fallback logic, different
    -- code path in _read_live_state; cover it explicitly.
    local ui = h.make_fake_ui({
        settings = {},                    -- doc_settings: never saved
        font     = { font_face = "Noto Serif" },  -- live default
    })
    local applied = RenderBridge.apply_from_remote(ui,
        { font_face = entry("OpenDyslexic", "2025-01-01 00:00:00") },
        toggles("master", "font_face"))
    h.assert_true(applied,
        "apply: font_face uses ui.font as its live-state fallback too -- "
        .. "a genuinely different peer font_face (OpenDyslexic vs this "
        .. "device's live Noto Serif) reports applied")
    h.assert_equal(ui._settings.font_face, "OpenDyslexic", "apply: font_face written")
end

do
    local ui = h.make_fake_ui({ settings = {} })
    RenderBridge.apply_from_remote(ui,
        { font_face = entry("Bitter", "2025-01-01 00:00:00") },
        toggles("master", "font_face"))
    h.assert_equal(ui._settings.font_face, "Bitter", "apply: font_face -> top-level key, unwrapped")
end

do
    -- apply must ALSO update the live in-memory state (the document's shared
    -- Configurable for copt_* keys, the ReaderFont module for font_face), or
    -- KOReader's ReaderConfig/ReaderFont onSaveSettings writes that unchanged
    -- live state back over our doc_settings write on close/flush/suspend, and
    -- the synced value silently vanishes before the next open.
    local configurable = { font_size = 20 }  -- live value loaded at open
    local font         = { font_face = "OldFont" }  -- live ReaderFont state
    local ui = h.make_fake_ui({
        settings     = { copt_font_size = 20, font_face = "OldFont" },
        configurable = configurable,
        font         = font,
    })

    RenderBridge.apply_from_remote(ui, {
        copt_font_size = entry(28, "2025-06-01 00:00:00"),
        font_face      = entry("NewFont", "2025-06-01 00:00:00"),
    }, toggles("master", "font_size", "font_face"))

    -- doc_settings written (existing behaviour)
    h.assert_equal(ui._settings.copt_font_size, 28, "apply writes copt_font_size to doc_settings")
    h.assert_equal(ui._settings.font_face, "NewFont", "apply writes font_face to doc_settings")
    -- AND the live state mirrored, so the next onSaveSettings stays consistent
    h.assert_equal(configurable.font_size, 28,
        "live configurable.font_size updated (else onSaveSettings clobbers it before next open)")
    h.assert_equal(font.font_face, "NewFont",
        "live ReaderFont.font_face updated (else onSaveSettings clobbers it before next open)")
end


-- ----------------------------------------------------------------------------
-- apply_from_remote — margins grouping
-- ----------------------------------------------------------------------------


do
    local ui = h.make_fake_ui({ settings = {} })
    RenderBridge.apply_from_remote(ui, {
        copt_h_page_margins = entry(15, "2025-01-01 00:00:00"),
        copt_t_page_margin  = entry(10, "2025-01-01 00:00:00"),
        copt_b_page_margin  = entry(10, "2025-01-01 00:00:00"),
    }, toggles("master", "margins"))
    h.assert_equal(ui._settings.copt_h_page_margins, 15, "apply margins: h written")
    h.assert_equal(ui._settings.copt_t_page_margin, 10, "apply margins: t written")
    h.assert_equal(ui._settings.copt_b_page_margin, 10, "apply margins: b written")
end

do
    local ui = h.make_fake_ui({ settings = {} })
    RenderBridge.apply_from_remote(ui, {
        copt_h_page_margins = entry(15, "2025-01-01 00:00:00"),
    }, toggles("master", "font_size")) -- margins off
    h.assert_nil(ui._settings.copt_h_page_margins, "apply: margins off -> not written")
end


-- ----------------------------------------------------------------------------
-- apply_from_remote — echo / stale guard (per-field)
-- ----------------------------------------------------------------------------


do
    -- Malformed (old whole-block raw value, not a {value,datetime} entry) -> skipped.
    local ui = h.make_fake_ui({ settings = {} })
    local applied = RenderBridge.apply_from_remote(ui,
        { copt_font_size = 24 }, toggles("master", "font_size"))
    h.assert_false(applied, "apply: raw (non-entry) value -> skipped")
    h.assert_nil(ui._settings.copt_font_size, "apply: malformed entry writes nothing")
end

do
    -- Applying the SAME entry twice: the second time is not strictly newer
    -- than the cached snapshot -> no-op (echo guard). Explicit starting
    -- value (18, not nil): this test is about the echo guard, not the
    -- first-ever-sync nil case -- an explicit prior value genuinely
    -- changing is what "applied1 = true" should mean here.
    local ui = h.make_fake_ui({ settings = { copt_font_size = 18 } })
    local e = { copt_font_size = entry(24, "2025-01-01 00:00:00") }
    local applied1 = RenderBridge.apply_from_remote(ui, e, toggles("master", "font_size"))
    local applied2 = RenderBridge.apply_from_remote(ui, e, toggles("master", "font_size"))
    h.assert_true(applied1, "apply: first time applies")
    h.assert_false(applied2, "apply: same entry again is a no-op (echo guard)")
end

do
    -- An empty datetime never applies.
    local ui = h.make_fake_ui({ settings = {} })
    local applied = RenderBridge.apply_from_remote(ui,
        { copt_font_size = entry(24, "") }, toggles("master", "font_size"))
    h.assert_false(applied, "apply: empty datetime -> not applied")
end
