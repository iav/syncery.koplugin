-- =============================================================================
-- spec/jump_toast_spec.lua
-- =============================================================================
--
-- Phase 14.2/14.4 — the jump invitation's pure MESSAGE
-- (syncery_ui/jump_toast.lua). As of 14.4 the show/finish control and the
-- overlay are owned by the notification coordinator (see notify_spec) and the
-- shared toast widget; this module is just the wording, so that is all we
-- assert here. A main.lua audit confirms the invite is routed through the
-- coordinator and the old blocking-modal builder is gone.
-- =============================================================================


local h = require("spec.test_helpers")

package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}
package.loaded["syncery_ui/jump_toast"] = nil
local JumpToast = require("syncery_ui/jump_toast")


-- --- message -----------------------------------------------------------------
do
    local m = JumpToast.message({ remote_label = "Kobo", page = 47 })
    h.assert_true(m:find("Kobo", 1, true) ~= nil, "message: includes the device label")
    h.assert_true(m:find("47", 1, true) ~= nil, "message: includes the page number")

    local p = JumpToast.message({ remote_label = "Tablet", percent = 0.5 })
    h.assert_true(p:find("50", 1, true) ~= nil, "message: percent fallback rounds to 50%")

    -- No chapter in this design (deliberately simpler than the non-touch
    -- buildContent below) -- percent/page is the whole "what".
    local c = JumpToast.message({ remote_label = "Kobo", percent = 0.45 })
    h.assert_true(c:find("45", 1, true) ~= nil, "message: percent shown")

    -- The page form is reserved for paging docs (fixed pages); when both a page
    -- and a percent are present, percent wins (the caller only passes page for
    -- PDFs, where it does NOT also pass percent -- this guards that ordering).
    local pp = JumpToast.message({ remote_label = "Kobo", percent = 0.45, page = 999 })
    h.assert_true(pp:find("45", 1, true) ~= nil and pp:find("999", 1, true) == nil,
        "message: percent takes precedence over page (page is PDF-only, never with percent)")

    local n = JumpToast.message({})
    h.assert_true(type(n) == "string" and #n > 0, "message: default label, no page/percent")
    h.assert_true(n:find("Another device", 1, true) ~= nil,
        "message: defaults the label to 'Another device'")

    -- No "is at"/"are at" verb anywhere -- symmetric "who, when — what" on
    -- both lines, so there is no tense to get wrong as the snapshot ages.
    h.assert_nil(m:find(" is at ", 1, true), "message: no 'is at' verb (tense-free by design)")
    h.assert_nil(m:find(" are at ", 1, true), "message: no 'are at' verb (tense-free by design)")

    h.assert_equal(JumpToast.actionLabel(), "Jump", "actionLabel is 'Jump'")
end


-- --- main.lua wiring + dead-code audit ---------------------------------------
do
    local f = io.open("main.lua", "r") or io.open("../main.lua", "r")
    h.assert_true(f ~= nil, "audit: could open main.lua")
    local src = f and f:read("*a") or ""
    if f then f:close() end

    -- The jump invite and the post-jump [Undo] confirmations are raised through
    -- the NON-BLOCKING bottom action bar (ActionBar.show -- a ReaderView view
    -- module + a button touch zone), NOT a toast/window, so the reader keeps
    -- paging. The new-annotation / new-render "[Reload]" affordance ALSO goes
    -- through ActionBar.show, but on LANE 1: the action bar stacks two
    -- INDEPENDENT lanes -- the jump/undo bar in lane 0 (bottom) and the reload in
    -- lane 1 (above it) -- so both are visible AT THE SAME TIME (position and
    -- content are independent axes; no queuing/sequencing). Four .show sites in
    -- main.lua: invite + the two undo bars (lane 0) + the reload (lane 1). The
    -- manual-jump bar lives in status_ui, audited there.
    h.assert_true(src:find('require("syncery_ui/action_bar")', 1, true) ~= nil,
        "wiring: the action bar module is required")
    local show_count = select(2, src:gsub("ActionBar%.show%(", ""))
    h.assert_equal(show_count, 4,
        "wiring: invite + 2 undo (lane 0) + reload (lane 1) all go through ActionBar.show (4 sites)")
    local defer_count = select(2, src:gsub("ActionBar%.defer%(", ""))
    h.assert_equal(defer_count, 0,
        "wiring: no ActionBar.defer -- the reload no longer queues, it shows on its own lane")
    -- The reload offer is on lane 1, so it stacks above (not preempts) the jump
    -- bar: exactly one `lane = 1` in main.lua, and it is the reload's show.
    local lane1_count = select(2, src:gsub("lane = 1", ""))
    h.assert_equal(lane1_count, 1,
        "wiring: the reload bar is shown on lane 1 (stacks above the lane-0 jump bar)")

    -- REGRESSION (the jump-vs-reload pre-emption bug): a shown jump bar must NOT
    -- silently DROP the pending reload. Previously checkRemote did
    --   if jump_shown then self._pending_ann_reload = nil; ... else offer end
    -- so a device reading on the SAME open re-fired the jump every checkRemote
    -- tick and re-dropped the reload -- the "N new annotations -- reload" bar
    -- never appeared in-session, and the receiving side re-pulled the same
    -- annotations on every close (the live ui.annotation list, which Syncery
    -- never mutates, was never refreshed). The fix offers the reload regardless
    -- of the jump (its OWN lane), so the old "jump bar IS up ... drop" branch is
    -- gone.
    h.assert_true(src:find("jump bar IS up", 1, true) == nil,
        "regression: jump no longer drops the pending reload (own lane instead)")
    -- Oscillation guard (same-page no-op jump): after should_prompt passes,
    -- checkRemote suppresses the prompt when the jump would NOT change the
    -- rendered page.  Without it two devices parked on the same page each
    -- re-stamp recency every save and, under auto-accept, jump to each other
    -- forever.  The check resolves the peer's xpath in OUR document (page
    -- numbers are not comparable across devices) and fails OPEN, so a resolution
    -- gap never silences a real jump.
    h.assert_true(src:find("function Syncery:_jumpChangesPage", 1, true) ~= nil,
        "wiring: the same-page oscillation guard exists")
    h.assert_true(src:find("if not self:_jumpChangesPage(state, best) then", 1, true) ~= nil,
        "wiring: checkRemote suppresses a no-op jump after should_prompt")
    h.assert_true(src:find("getPageFromXPointer", 1, true) ~= nil,
        "wiring: the guard resolves the peer xpath to a LOCAL page")
    h.assert_true(src:find("rolling without a resolvable xpath: fail open", 1, true) ~= nil,
        "wiring: the guard fails OPEN for rolling docs (device-local pages never silence a real jump)")

    -- The action bar stacks two independent lanes: per-lane view-module / touch-
    -- zone identity (view_key), M.show places the bar on spec.lane and preempts
    -- only the SAME lane, and M.dismiss tears down EVERY lane on document leave.
    do
        local af = io.open("syncery_ui/action_bar.lua", "r")
            or io.open("../syncery_ui/action_bar.lua", "r")
        h.assert_true(af ~= nil, "audit: could open action_bar.lua")
        local asrc = af and af:read("*a") or ""
        if af then af:close() end
        h.assert_true(asrc:find("function view_key(lane)", 1, true) ~= nil,
            "wiring: action_bar keys view modules per lane (view_key)")
        h.assert_true(asrc:find("local lane = spec.lane or 0", 1, true) ~= nil,
            "wiring: M.show places the bar on spec.lane")
        h.assert_true(asrc:find("for lane = 0, LANE_COUNT - 1 do", 1, true) ~= nil,
            "wiring: M.dismiss tears down EVERY lane on document leave")
        h.assert_true(asrc:find("function M.defer", 1, true) == nil,
            "wiring: M.defer is gone (independent lanes replace the queue/drain)")
        -- Lane overlap (finding C): the higher lane RESERVES the lower lane's
        -- worst case up front, so the two never overlap in any appearance order
        -- -- and NO shown bar is re-laid-out (a jerk under a touch mis-routes it).
        h.assert_true(asrc:find("function lower_lane_reserve", 1, true) ~= nil,
            "geometry: a fixed worst-case reserve lifts the higher lane")
        h.assert_true(asrc:find("below_h + lower_lane_reserve()", 1, true) ~= nil,
            "geometry: the lift reserves the lower lane's worst case, not this bar's own height")
        h.assert_true(asrc:find("_lane_heights", 1, true) == nil,
            "geometry: no last-shown-height fallback (it under-reserved a taller later lane 0)")
    end
    -- Reload affordance: when checkRemote applies changes that are only visible
    -- at the next open (annotations -- live list not mutated mid-session; AND
    -- font & layout -- copt_* written but not re-rendered) and no position jump
    -- pre-empts, _maybeOfferReload shows a [Reload] bar that triggers
    -- ReaderUI:reloadDocument (its close stages both; the reopen loads them).
    -- Metadata is NOT here -- it applies live and needs no reload.
    h.assert_true(src:find("_maybeOfferReload", 1, true) ~= nil,
        "wiring: the reload offer helper exists")
    h.assert_true(src:find("self.ui:reloadDocument()", 1, true) ~= nil,
        "wiring: the [Reload] button triggers ReaderUI:reloadDocument")
    -- Opt-out (issue #11): default ON.  When off, _maybeOfferReload returns
    -- before the bar -- merged content still lands on the next open (already
    -- staged), just no mid-session interruption.
    h.assert_true(src:find("if not self.reload_prompt then return end", 1, true) ~= nil,
        "wiring: _maybeOfferReload honours the reload_prompt opt-out")
    h.assert_true(src:find('read_bool%("syncery_reload_prompt",%s+true%)') ~= nil,
        "wiring: reload_prompt loads default ON")
    do
        local mf = io.open("syncery_ui/menu/init.lua", "r")
            or io.open("../syncery_ui/menu/init.lua", "r")
        h.assert_true(mf ~= nil, "audit: could open menu/init.lua")
        local msrc = mf and mf:read("*a") or ""
        if mf then mf:close() end
        h.assert_true(msrc:find('makeBoolToggle(plugin, "reload_prompt", "syncery_reload_prompt"', 1, true) ~= nil,
            "wiring: Advanced menu exposes the reload-prompt opt-out toggle")
    end
    h.assert_true(src:find("self._pending_ann_reload = result.annotations_pulled", 1, true) ~= nil,
        "wiring: a remote annotation pull arms the reload offer (annotations_pulled)")
    -- Font & layout (render) changes arm the SAME affordance -- they too are only
    -- visible at the next open, so they share the [Reload] bar.
    h.assert_true(src:find("self._pending_render_reload = true", 1, true) ~= nil,
        "wiring: an applied render change arms the reload offer (render_applied)")
    -- The bar text names exactly which section(s) changed: annotations-only
    -- (plural-counted), render-only, or both.
    h.assert_true(src:find("%d new annotation from another device", 1, true) ~= nil,
        "text: annotations-only reload message (plural-counted)")
    h.assert_true(src:find("New font & layout from another device", 1, true) ~= nil,
        "text: render-only reload message")
    h.assert_true(src:find("New annotations and font & layout from another device", 1, true) ~= nil,
        "text: combined annotations + render reload message")
    -- The old notify-coordinator invite is gone (it was a blocking window).
    h.assert_nil(src:find("Notify.notifyInvite", 1, true),
        "dead code: the jump invite no longer uses the notify invite (now the action bar)")
    -- The ask-path jump confirms with the "Jumped to new position." bar.
    h.assert_true(src:find("Jumped to new position.", 1, true) ~= nil,
        "wiring: ask-path jump confirms via the action bar")

    -- The jump invite no longer shows the remote device's PAGE for reflowable
    -- books: that page is device-local (each device re-paginates for its own
    -- font/screen).  The ask path branches on the shared xpointer -- reflowable
    -- (xpath present) -> percent + the chapter resolved FROM that xpointer
    -- (_resolveChapter, via ui.toc:getTocTitleByPage which takes an xpointer
    -- directly); paging (PDF, no xpointer) -> the fixed page, which is the same
    -- across devices.  The old unconditional `page = opts.r_page` is gone.
    h.assert_true(src:find("function Syncery:_resolveChapter", 1, true) ~= nil,
        "wiring: the xpointer->chapter resolver helper exists")
    h.assert_true(src:find("getTocTitleByPage", 1, true) ~= nil,
        "wiring: chapter resolved via the in-memory TOC (getTocTitleByPage on the xpointer)")
    h.assert_true(src:find("jump_opts.chapter = self:_resolveChapter", 1, true) ~= nil,
        "wiring: the ask-path invite passes the resolved chapter (reflowable branch)")
    h.assert_true(src:find("jump_opts.page = opts.r_page", 1, true) ~= nil,
        "wiring: the paging (PDF) branch still shows the fixed page")
    h.assert_true(src:find("pcall(function() return ui.toc:getTocTitleByPage", 1, true) ~= nil,
        "wiring: chapter resolution is pcall-guarded (getTocTitleByPage crashes on non-string)")
    -- The post-jump undo window (pre_jump_until, set by _doJump) is 60 seconds.
    h.assert_true(src:find("pre_jump_until = os.time() + 60", 1, true) ~= nil,
        "wiring: the post-jump undo window is 60 seconds")
    -- jump_mode "never" suppresses the automatic prompt entirely.
    h.assert_true(src:find('self.jump_mode == "never"', 1, true) ~= nil,
        "wiring: _promptJump suppresses the prompt in 'never' mode")
    -- ...but "never" gates ONLY the position axis: the reload bar is a different
    -- axis and must still be offered when no jump bar competes.  checkRemote
    -- captures whether _promptJump actually raised a bar (true = ask/auto bar
    -- shown; false = "never" declined) and offers the reload on the declined
    -- path instead of dropping it -- so "never" cannot silently swallow incoming
    -- annotations / render until the next open.  That makes FOUR no-jump-bar
    -- reload paths: `not best`, `not should_prompt`, the same-page oscillation
    -- guard (`not _jumpChangesPage`), and "never".
    h.assert_true(src:find("local jump_shown = self:_promptJump", 1, true) ~= nil,
        "wiring: checkRemote captures whether _promptJump raised a jump bar")
    local reload_calls = select(2, src:gsub("self:_maybeOfferReload%(%)", ""))
    h.assert_equal(reload_calls, 4,
        "wiring: reload offered at all no-jump-bar paths (not best / not should_prompt / same-page / 'never')")
    -- jump_mode "auto" short-circuits straight to the jump.
    h.assert_true(src:find('self.jump_mode == "auto"', 1, true) ~= nil,
        "wiring: _promptJump auto-jumps in 'auto' mode")
    -- The blocking-modal message builder is long gone.
    h.assert_nil(src:find("function Syncery:_buildJumpMessage", 1, true),
        "dead code: _buildJumpMessage removed")
    h.assert_nil(src:find("Jump there?", 1, true),
        "dead code: the old modal 'Jump there?' message is gone")
    -- The superseded standalone show-controller is no longer wired.
    h.assert_nil(src:find("JumpToast.show", 1, true),
        "dead code: the standalone JumpToast.show wiring is gone (notify owns it)")
    h.assert_nil(src:find("JumpToastWidget", 1, true),
        "dead code: JumpToastWidget require/use removed (toast_widget supersedes it)")
end


-- ----------------------------------------------------------------------------
-- From -> to context line: WHEN the peer was there + where the reader is NOW.
-- ----------------------------------------------------------------------------

do
    local msg = JumpToast.message{
        remote_label = "Kindle5", percent = 0.42,
        timestamp = os.time() - 3 * 3600, local_percent = 0.301,
    }
    h.assert_true(msg:find("Kindle5", 1, true) ~= nil, "ctx: device label present")
    h.assert_true(msg:find("42%%") ~= nil,              "ctx: peer percent present")
    h.assert_true(msg:find("3 h", 1, true) ~= nil,      "ctx: relative time present (not an absolute date, no 'ago')")
    h.assert_true(msg:find("\n") ~= nil,                "ctx: second line present")
    h.assert_true(msg:find("This Device", 1, true) ~= nil, "ctx: 'This Device' label present")
    h.assert_nil(msg:find("now", 1, true),
        "ctx: no 'now' for the local side (own position is trivially always-now, so omitted)")
    h.assert_true(msg:find("30%%") ~= nil,              "ctx: local percent present")
end

do
    local msg = JumpToast.message{
        remote_label = "K3", page = 120, local_page = 96, timestamp = os.time() - 3 * 3600,
    }
    h.assert_true(msg:find("page 96", 1, true) ~= nil, "ctx: paging docs show local page")
end

do
    local msg = JumpToast.message{ remote_label = "K3", percent = 0.5 }
    h.assert_nil(msg:find("\n"), "ctx: no second line when there is no local position to show")
end

-- ---------------------------------------------------------------------------
-- fields() — the here/there cells that buildContent lays out.  (buildContent
-- itself needs KOReader widgets, so only the pure field derivation is tested.)
-- ---------------------------------------------------------------------------
do
    local f = JumpToast.fields{
        remote_label = "Kobo", percent = 0.45, chapter = "Chapter 7",
        local_percent = 0.30, local_chapter = "Chapter 3", timestamp = os.time() - 3 * 3600,
    }
    h.assert_equal(f.peer_label, "Kobo", "fields: peer label is the remote device")
    h.assert_true(f.peer_unit:find("45", 1, true) ~= nil, "fields: peer unit is the percent")
    h.assert_equal(f.peer_chapter, "Chapter 7", "fields: peer chapter kept separate")
    h.assert_true(f.here_unit:find("30", 1, true) ~= nil, "fields: here unit is the local percent")
    h.assert_equal(f.here_chapter, "Chapter 3", "fields: here chapter kept separate")
    h.assert_equal(f.timestamp, "3 h",
        "fields: timestamp resolved to compact relative time, standalone (not glued to a unit)")
    h.assert_nil(f.here_unit:find("%d%d%d%d", 1, false),
        "fields: the timestamp is NOT part of a unit cell")
end

do
    -- Paging docs: the unit is the page; no chapters resolve.
    local f = JumpToast.fields{ remote_label = "K3", page = 120, local_page = 96 }
    h.assert_true(f.peer_unit:find("120", 1, true) ~= nil, "fields: paging peer unit is the page")
    h.assert_true(f.here_unit:find("96", 1, true) ~= nil, "fields: paging here unit is the local page")
    h.assert_equal(f.peer_chapter, "—", "fields: no chapter -> em-dash placeholder")
end

do
    -- Absent inputs -> sensible, non-nil defaults.
    local f = JumpToast.fields{}
    h.assert_true(f.here_label ~= "" and f.peer_label ~= "", "fields: labels always present")
    h.assert_equal(f.peer_chapter, "—", "fields: absent chapter -> em-dash placeholder")
    h.assert_nil(f.timestamp, "fields: no timestamp when absent")
end
