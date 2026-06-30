-- =============================================================================
-- syncery_ui/action_bar.lua
-- =============================================================================
--
-- A NON-BLOCKING, bottom-anchored bar with a single tappable button, used for
-- the jump invitation ([Jump]) and the post-jump undo ([Undo]). Replaces the
-- two jump toasts, which blocked page turns.
--
-- WHY NOT A TOAST/WINDOW: a UIManager window -- even a "toast" -- that sits at
-- the top of the window stack stops gesture propagation to the reader
-- (UIManager:sendEvent walks down to the first NON-toast widget and stops
-- there), so page turns are blocked while it is up. KOReader's own
-- non-blocking Notification sets `toast = true`, but that is non-interactive:
-- it closes on ANY input, and a Button inside it would leak the tap to the
-- reader (toast=true ignores the handler's return, so the tap still reaches
-- ReaderUI). KOReader has no built-in interactive non-blocking toast.
--
-- HOW THIS IS NON-BLOCKING: the bar is NOT a window. It is
--   (1) a ReaderView VIEW MODULE -- registered via view:registerViewModule, so
--       ReaderView paints it over each page as part of its own render
--       (readerview.lua paintTo loop). It is never in the input/window stack,
--       and it persists across page turns automatically (every reader repaint
--       repaints it); and
--   (2) the button is a TOUCH ZONE -- registered via ui:registerTouchZones with
--       `overrides = { "tap_forward", "tap_backward", ... }`, so a tap on the
--       button's rect is consumed by us (the zone is ordered before the
--       page-turn zones and our handler returns true -> inputcontainer.lua:261
--       stops), while taps/swipes ANYWHERE else fall through to the reader's
--       normal page-turn zones. No leak, no block.
--   The drawn Button is for its LOOK only; input is the zone (the view module
--   is not an input widget, so the Button's own callback never fires).
--
-- LIFECYCLE: M.show(ui, spec) registers the module + the button zone and
-- schedules an auto-dismiss (spec.seconds). The bar tears itself down on the
-- button tap (-> spec.on_action), on timeout (-> spec.on_timeout), or when a
-- new bar pre-empts it. Teardown unregisters the zone, drops the view module,
-- cancels the timer, and setDirty()s the bottom strip so the page redraws
-- underneath.
--
-- This module require()s real KOReader widgets and drives ReaderView /
-- touch-zone internals, so it loads only inside a running KOReader (main.lua
-- wires it; no spec require()s it). Its render / touch-alignment / e-ink
-- refresh behaviour is NOT exercised by the headless test matrix and must be
-- verified (and likely tuned) on-device.
-- =============================================================================


local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button          = require("ui/widget/button")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Screen = Device.screen

-- Non-touch fallback serialization state (module-level: ONE slot for the whole
-- plugin, shared by M.show_focusable and M.showExclusive). The touch path can
-- stack two bars at once (lane 0 jump/undo + lane 1 reload); the focusable
-- fallback is a modal ButtonDialog, so two at once -- or a reload/undo behind the
-- modal ask-jump ConfirmBox -- would hide each other while both auto-close timers
-- ran, expiring the hidden one unseen. So only ONE is live at a time; the rest
-- queue FIFO and arm their timer only when they surface.
local fb_active = false
local fb_queue  = {}    -- FIFO: focusable specs OR { exclusive = run_fn }
local fb_dialog = nil   -- the live focusable ButtonDialog (for teardown cleanup)
local fb_timer  = nil   -- its scheduled auto-close timer fn (to unschedule on teardown)
local fb_modal  = nil   -- the live foreign modal (ask-jump ConfirmBox) holding the slot
local fb_tearing = false -- true while M.dismiss tears down: suppresses fb_drain so a
                         -- close-callback can't resurrect a queued dialog mid-teardown
local fb_drain          -- forward decl (defined with the queue helpers below)

local VIEW_KEY_BASE = "syncery_action_bar"
local ZONE_ID_BASE  = "syncery_action_bar_tap"
local LANE_COUNT    = 2  -- lane 0 = jump/undo (bottom), lane 1 = reload (above)
-- Per-lane view-module / touch-zone identity so the lanes are INDEPENDENT:
-- showing the reload (lane 1) never preempts the jump (lane 0), or vice versa.
local function view_key(lane) return VIEW_KEY_BASE .. (lane or 0) end
local function zone_id(lane)  return ZONE_ID_BASE  .. (lane or 0) end

-- Lift the bar off the very bottom by this fraction of screen height, so the
-- jump / undo / annotation bars all sit a bit higher (clear of the footer).
-- ~0.08 lands the button row around 90% down (was ~98%). Tune freely.
local BOTTOM_MARGIN_RATIO = 0.08

-- The reader zones our button must sit ON TOP of, so a tap on it is consumed
-- instead of turning a page / toggling the footer. Mirrors the list ReaderLink
-- uses for tap-to-follow-link (readerlink.lua).
local TURN_OVERRIDES = {
    "tap_forward", "tap_backward",
    "readerfooter_tap",
    "tap_top_left_corner", "tap_top_right_corner",
    "tap_left_bottom_corner", "tap_right_bottom_corner",
}


-- --- the drawn widget (a ReaderView view module) -----------------------------
local ActionBar = WidgetContainer:extend{
    text         = nil,
    button_label = nil,
    show_close   = false,  -- when true, render a compact [✕] dismiss button to
                           -- the right of the action button (a manual "close
                           -- this message" = same effect as the auto-timeout)
    lane         = 0,  -- 0 = bottom (jump/undo), 1 = above it (reload)
}

function ActionBar:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local frame_pad = Size.padding.default
    local avail_w   = math.floor(screen_w * 0.96)  -- almost full width

    -- Button is drawn for its look; the no-op callback never fires (input is
    -- the touch zone, since a view module is not an input widget).
    local button = Button:new{
        text     = self.button_label,
        radius   = Size.radius.button,
        callback = function() end,
    }
    local gap   = Size.span.horizontal_default

    -- Optional compact [✕] dismiss button (jump bars).  Its tap runs the SAME
    -- teardown path as the auto-timeout (see M.show), so closing it early is
    -- exactly "the 12s elapsed now" -- no separate state.
    local close_button = nil
    local close_reserve = 0
    if self.show_close then
        close_button = Button:new{
            text     = "  ✕  ",
            radius   = Size.radius.button,
            callback = function() end,
        }
        close_reserve = close_button:getSize().w + gap
    end

    local msg_w = avail_w - button:getSize().w - gap - close_reserve - (frame_pad * 4)
    if msg_w < Size.item.height_default then
        msg_w = math.floor(avail_w * 0.5)
    end

    local message = TextBoxWidget:new{
        text  = self.text,
        face  = Font:getFace("infofont"),
        width = msg_w,
    }

    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, message)
    table.insert(row, HorizontalSpan:new{ width = gap })
    table.insert(row, button)
    if close_button then
        table.insert(row, HorizontalSpan:new{ width = gap })
        table.insert(row, close_button)
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius     = Size.radius.window,
        padding    = frame_pad,
        margin     = Size.margin.default,
        row,
    }

    self.frame  = frame
    self.button = button
    self.close_button = close_button

    -- Lane STACKING: lane 0 sits at the base margin; each higher lane is lifted
    -- by one (this bar's) frame height + a small gap, so multiple bars stack
    -- bottom-up without overlapping -- the position-jump bar (lane 0) and the
    -- [Reload] content affordance (lane 1) are INDEPENDENT axes (position vs
    -- content) and show at the same time, one above the other.  Lane 1 lifts by
    -- its OWN (the reload bar's) height; the reload message is the longest, so
    -- its height >= the jump bar's and lane 1 always clears lane 0.
    -- Span the screen MINUS that bottom margin for layout (consumes no input --
    -- the view module is never in the input stack). BottomContainer centres and
    -- bottom-anchors the frame within this shorter height, so the frame's bottom
    -- edge lands at (screen_h - bottom_margin) -- lifting the whole bar.
    local fsz           = frame:getSize()
    local lane          = self.lane or 0
    local lane_gap      = math.floor(screen_h * 0.02)
    local bottom_margin = math.floor(screen_h * BOTTOM_MARGIN_RATIO)
                        + lane * (fsz.h + lane_gap)
    self[1] = BottomContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h - bottom_margin },
        frame,
    }

    -- Geometry, from the laid-out sizes. The bar is centred and sits
    -- bottom_margin above the very bottom, exactly as BottomContainer paints it.
    local frame_x = math.floor((screen_w - fsz.w) / 2)
    local frame_y = screen_h - bottom_margin - fsz.h

    -- self.dimen MUST stay FULL-SCREEN. ReaderView paints us via
    -- WidgetContainer:paintTo, which offsets self[1] by self.dimen.x/y BEFORE
    -- painting -- and self[1] is a BottomContainer that ALREADY bottom-anchors
    -- the frame. A bottom-strip dimen here gets ADDED to BottomContainer's own
    -- bottom offset, painting the bar ~one screen-height BELOW the visible area
    -- (off-screen / invisible). Keep dimen full-screen so our offset is (0,0)
    -- and only BottomContainer positions the frame.
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    -- e-ink refresh region (the bottom strip the bar actually occupies), kept
    -- SEPARATE from self.dimen so it can't perturb the paint offset above. Full
    -- width so the whole bar redraws on show/dismiss regardless of small
    -- centring drift (no ghost sliver). The bar is almost full width anyway.
    self.bar_region = Geom:new{ x = 0, y = frame_y, w = screen_w, h = fsz.h }

    -- Button touch rect(s): the right end of the frame.  Without a close
    -- button the action button is rightmost (existing geometry).  WITH a close
    -- button the order is [message][action][✕], so [✕] is rightmost and the
    -- action button sits one (button width + gap) to its left.  Each rect is
    -- padded so small layout-math drift still lands on it; taps elsewhere
    -- (the message, outside) fall through to the reader.  In the two-button
    -- case the two rects are split at the MIDPOINT of the inter-button gap so
    -- they meet without overlapping (an overlap would mis-route a boundary tap
    -- to whichever zone registered first).  Tune on-device if a target feels off.
    local inset = Size.margin.default + Size.border.window + frame_pad
    local bsz   = button:getSize()
    local btn_y = frame_y + inset + math.floor(((fsz.h - 2 * inset) - bsz.h) / 2)

    if close_button then
        local csz     = close_button:getSize()
        local pad     = Size.padding.default
        local close_x = frame_x + fsz.w - inset - csz.w
        local btn_x   = close_x - gap - bsz.w
        local close_y = frame_y + inset + math.floor(((fsz.h - 2 * inset) - csz.h) / 2)
        -- Boundary at the middle of the gap between the two buttons.
        local mid     = math.floor(close_x - gap / 2)
        local left    = math.max(0, btn_x - pad)
        self.button_zone = Geom:new{
            x = left,
            y = math.max(0, btn_y - pad),
            w = math.max(1, mid - left),
            h = bsz.h + 2 * pad,
        }
        self.close_zone = Geom:new{
            x = mid,
            y = math.max(0, close_y - pad),
            w = math.max(1, (close_x + csz.w + pad) - mid),
            h = csz.h + 2 * pad,
        }
    else
        local pad   = Size.padding.large
        local btn_x = frame_x + fsz.w - inset - bsz.w
        self.button_zone = Geom:new{
            x = math.max(0, btn_x - pad),
            y = math.max(0, btn_y - pad),
            w = bsz.w + 2 * pad,
            h = bsz.h + 2 * pad,
        }
    end
end


-- --- show / dismiss lifecycle ------------------------------------------------
local M = {}

-- Tear down lane `lane`'s bar (if any). `which` selects the callback: "action"
-- (button tapped) runs on_action, "timeout" runs on_timeout, anything else
-- (e.g. "preempt") runs neither.  Each lane is torn down independently.
local function teardown(ui, which, lane)
    lane = lane or 0
    local vk  = view_key(lane)
    local bar = ui and ui.view and ui.view.view_modules[vk]
    if not bar or bar._finished then return end
    bar._finished = true

    if bar._timer then
        UIManager:unschedule(bar._timer)
        bar._timer = nil
    end
    pcall(function()
        ui:unRegisterTouchZones({ { id = zone_id(lane), overrides = TURN_OVERRIDES } })
    end)
    if bar.close_zone then
        pcall(function()
            ui:unRegisterTouchZones({ { id = zone_id(lane) .. "_close", overrides = TURN_OVERRIDES } })
        end)
    end

    local region = bar.bar_region
    ui.view.view_modules[vk] = nil
    if region then
        UIManager:setDirty(ui, "ui", region)
    end

    if which == "action" and bar._on_action then
        pcall(bar._on_action)
    elseif which == "timeout" and bar._on_timeout then
        pcall(bar._on_timeout)
    end
end

-- Show a bar. `spec` = {
--   text         = string,     -- the message
--   button_label = string,     -- the button caption
--   on_action    = function,   -- run when the button is tapped
--   on_timeout   = function,   -- (optional) run if it auto-dismisses untapped
--   seconds      = number,     -- auto-dismiss delay (default 12)
--   lane         = number,     -- (optional) 0 = bottom jump/undo, 1 = reload
--   show_close   = boolean,    -- (optional) add a [✕] dismiss button; tapping
--                              -- it runs on_timeout (manual "close now" ==
--                              -- the auto-timeout firing now)
-- }
-- Only the SAME lane is preempted, so a lane-1 reload coexists with a lane-0
-- jump bar (both visible, stacked) -- they are independent axes.
function M.show(ui, spec)
    -- Non-touch devices: the bar's button is a touch zone with no key path, so
    -- it is unreachable (and an un-pressable button is alarming). Route EVERY
    -- caller (jump/undo/reload, here and in the status panel / progress browser)
    -- to the focusable, auto-dismissing variant instead. (The "ask" invite is
    -- already handled separately as a ConfirmBox before reaching here.)
    if not Device:isTouchDevice() then
        return M.show_focusable(spec)
    end
    if not (ui and ui.view and ui.registerTouchZones and ui.view.registerViewModule) then
        return
    end
    local lane = spec.lane or 0
    teardown(ui, "preempt", lane)  -- one bar PER LANE at a time

    local bar = ActionBar:new{
        text = spec.text, button_label = spec.button_label,
        show_close = spec.show_close, lane = lane,
    }
    bar._on_action  = spec.on_action
    bar._on_timeout = spec.on_timeout

    ui.view:registerViewModule(view_key(lane), bar)

    local z = bar.button_zone
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    ui:registerTouchZones({
        {
            id  = zone_id(lane),
            ges = "tap",
            screen_zone = {
                ratio_x = z.x / sw, ratio_y = z.y / sh,
                ratio_w = z.w / sw, ratio_h = z.h / sh,
            },
            overrides = TURN_OVERRIDES,
            -- return true => consume the tap (no page turn); see
            -- inputcontainer.lua:261.
            handler = function() teardown(ui, "action", lane); return true end,
        },
    })

    -- Optional [✕] dismiss zone.  Tapping it tears the bar down via the SAME
    -- "timeout" path as the auto-dismiss timer (runs on_timeout) -- a manual
    -- close is exactly "the dwell elapsed now", so no separate callback or
    -- state is needed.  Registered as its own zone id so teardown drops both.
    if bar.close_zone then
        local cz = bar.close_zone
        ui:registerTouchZones({
            {
                id  = zone_id(lane) .. "_close",
                ges = "tap",
                screen_zone = {
                    ratio_x = cz.x / sw, ratio_y = cz.y / sh,
                    ratio_w = cz.w / sw, ratio_h = cz.h / sh,
                },
                overrides = TURN_OVERRIDES,
                handler = function() teardown(ui, "timeout", lane); return true end,
            },
        })
    end

    bar._timer = UIManager:scheduleIn(spec.seconds or 12, function()
        teardown(ui, "timeout", lane)
    end)

    UIManager:setDirty(ui, "ui", bar.bar_region)
    return bar
end

-- Dismiss EVERY lane without running any callback (e.g. when leaving the
-- document): both the jump/undo lane and the reload lane.
function M.dismiss(ui)
    for lane = 0, LANE_COUNT - 1 do
        teardown(ui, "preempt", lane)
    end
    -- Reset the non-touch fallback slot too: fb_* are module-level and outlive
    -- the per-book plugin instance, so a focusable dialog still open (or a queued
    -- entry) at document teardown would otherwise leave the slot stuck and make
    -- every future fallback queue forever.
    -- Order matters: empty the queue and raise fb_tearing BEFORE closing anything,
    -- so a close-callback that reaches fb_drain can't surface a queued dialog
    -- mid-teardown. Cancel the live auto-close timer too (else it fires later onto
    -- a closed dialog), then close the live focusable dialog AND any foreign modal
    -- (the ask-jump ConfirmBox) holding the slot.
    fb_tearing = true
    fb_queue = {}
    fb_active = false
    if fb_timer then
        pcall(function() UIManager:unschedule(fb_timer) end)
        fb_timer = nil
    end
    if fb_dialog then
        pcall(function() UIManager:close(fb_dialog) end)
        fb_dialog = nil
    end
    if fb_modal then
        pcall(function() UIManager:close(fb_modal) end)
        fb_modal = nil
    end
    fb_tearing = false
end

-- (queue state — fb_active / fb_queue / fb_dialog / fb_drain — declared at the
-- module top so M.dismiss can reset it on document teardown.)

fb_drain = function()
    fb_active = false
    if fb_tearing then return end   -- mid-teardown: never surface a queued dialog
    local item = table.remove(fb_queue, 1)
    if not item then return end
    if item.exclusive then
        item.exclusive()         -- a queued foreign modal (the ask-jump ConfirmBox)
    else
        M.show_focusable(item)   -- a queued timer dialog (undo / reload)
    end
end

-- Non-touch fallback for the single-action bars (undo / reload). The bar above
-- is touch-only -- its button is a touch zone with no key path -- so on a device
-- with no touchscreen it is unreachable. Show a focusable, auto-dismissing
-- dialog instead: the lone action button is focused, so ONE key press runs it;
-- if left untouched it closes after `seconds` WITHOUT running the action --
-- exactly the touch bar's timeout (the jump stays / the reload is skipped).
-- spec = { text, button_label, on_action, on_timeout, seconds }
function M.show_focusable(spec)
    if fb_active then
        -- Something is already on screen; queue this one. Its timer is NOT armed
        -- until it surfaces (in a later fb_drain), so it can't expire unseen.
        table.insert(fb_queue, spec)
        return
    end
    fb_active = true
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog, timer
    local done = false
    local function finish(run_action)
        if done then return end
        done = true
        if timer then UIManager:unschedule(timer) end
        if fb_timer == timer then fb_timer = nil end
        if fb_dialog == dialog then fb_dialog = nil end
        UIManager:close(dialog)
        if run_action then
            if spec.on_action then pcall(spec.on_action) end
        elseif spec.on_timeout then
            pcall(spec.on_timeout)
        end
        fb_drain()  -- surface the next queued fallback, if any
    end
    dialog = ButtonDialog:new{
        title       = spec.text,
        title_align = "center",
        -- Single button, focused by default on D-pad devices (FocusManager
        -- paints the highlight on selected={1,1}) → reachable with one [Press].
        -- Back / auto-timeout = no-op (e.g. the jump stays, the reload is skipped).
        tap_close_callback = function() finish(false) end,
        buttons     = { { { text = spec.button_label, callback = function() finish(true) end } } },
    }
    fb_dialog = dialog
    timer = function() finish(false) end
    UIManager:show(dialog)
    UIManager:scheduleIn(spec.seconds or 12, timer)
    fb_timer = timer  -- module-level handle so M.dismiss can unschedule on teardown
    return dialog
end

-- Show a foreign modal (the ask-jump ConfirmBox) THROUGH the same single slot,
-- so it never covers an active fallback (it queues instead) and reloads never
-- expire behind it (they queue too). `show_fn(release)` must display the modal;
-- call `release` from its close paths (ok AND cancel -- ConfirmBox:onClose runs
-- cancel_callback on Back / tap-outside too, so the slot is always freed).
-- `release(false)` frees the slot WITHOUT draining the queue, so an imminent
-- post-jump undo can claim it before any queued reload (undo shown before reload).
function M.showExclusive(show_fn)
    local function run()
        fb_active = true
        local released = false
        -- show_fn must RETURN the modal widget it displayed, so M.dismiss can
        -- close it on document teardown (it lives outside this module otherwise).
        fb_modal = show_fn(function(drain)
            if released then return end
            released = true
            fb_modal = nil
            if drain == false then
                fb_active = false   -- let the next show_focusable (undo) take the slot
            else
                fb_drain()
            end
        end)
    end
    if fb_active then
        table.insert(fb_queue, { exclusive = run })
        return
    end
    run()
end

return M
