-- =============================================================================
-- syncery_ui/jump_toast.lua
-- =============================================================================
--
-- The short "another device moved ahead" invitation MESSAGE.
--
-- When jump_mode is "ask", _promptJump raises a non-blocking invitation.
-- The SHOW/finish control and the actual overlay are owned by the
-- notification coordinator (syncery_ui/notify.lua) and the shared toast widget
-- (syncery_ui/toast_widget.lua) respectively; this module is now just the
-- pure message + action label that the invite carries. Keeping it separate
-- keeps the wording (and its Bulgarian translations) unit-testable.
--
-- Strings via _(); Bulgarian lives in locale/bg.po.
-- =============================================================================


local I18n = require("syncery_i18n")
local _    = I18n.translate
local _n   = I18n.ngettext


local JumpToast = {}


-- Compact relative time bucket ("<1 min", "2 days", "1 week", "4 months",
-- "1 year"), for the peer's recency badge. jump_toast-local by design: the 6
-- other "N ago" spots in this codebase (booklist, status panels, trash) are
-- each a PERSISTENT screen, not a transient toast, and were deliberately
-- left alone rather than force-migrated to this format. Minutes/hours use a
-- short, non-inflecting unit ("min"/"h") since they don't need a plural
-- form; day/week/month/year are properly pluralized via ngettext (English
-- "1 day" vs "2 days"; Bulgarian's own singular/plural forms, independent
-- rule, via the .po file's plural entries -- NOT assumed to mirror
-- English's). Returns nil for a missing/non-positive timestamp (caller
-- omits the badge/line entirely).
function JumpToast._relativeAgo(timestamp)
    if type(timestamp) ~= "number" or timestamp <= 0 then return nil end
    local age = os.difftime(os.time(), timestamp)
    -- Clock skew (remote's clock briefly ahead of ours): clamp to the
    -- lowest bucket rather than showing a negative/nonsensical duration.
    if age < 0 then age = 0 end
    if age < 60 then
        return _("<1 min")
    elseif age < 3600 then
        return string.format(_("%d min"), math.floor(age / 60))
    elseif age < 86400 then
        return string.format(_("%d h"), math.floor(age / 3600))
    elseif age < 604800 then
        local n = math.floor(age / 86400)
        return string.format(_n("%d day", "%d days", n), n)
    elseif age < 2592000 then -- < 30 days
        local n = math.floor(age / 604800)
        return string.format(_n("%d week", "%d weeks", n), n)
    elseif age < 31536000 then -- < 365 days
        local n = math.floor(age / 2592000)
        return string.format(_n("%d month", "%d months", n), n)
    else
        local n = math.floor(age / 31536000)
        return string.format(_n("%d year", "%d years", n), n)
    end
end


-- The invitation message. `opts`:
--   remote_label  string|nil  device name (defaults to "Another device")
--   percent       number|nil  fraction 0..1 -- the cross-device-stable unit
--   page          number|nil  a FIXED page number -- only for paging docs
--                             (PDF/CBZ), where pages coincide across devices
--   timestamp     number|nil  when the remote device was there (unix)
--   local_percent number|nil  THIS device's current fraction 0..1
--   local_page    number|nil  THIS device's current page (paging docs)
--
-- The remote device's stored PAGE is device-LOCAL for reflowable books (each
-- device re-lays-out the text with its own font/screen), so it is never shown
-- for them -- the caller passes `percent` instead, and passes `page` only for
-- paging docs whose pages are identical everywhere. No chapter here (kept
-- deliberately simpler than the non-touch buildContent below).
--
-- Symmetric "who, when — what" structure on both lines -- no "is at"/"are
-- at" verb, so there is no tense to get wrong as the peer's snapshot ages
-- (see session history: "is at" reads as still-true, "was at" undersells the
-- very recency that made the prompt fire at all -- dropping the verb
-- sidesteps the problem instead of picking a side). Recency, not position,
-- is the actual reason a prompt exists at all (jump_policy.lua: "forward
-- means newer, not necessarily ahead in the document") -- leading each line
-- with the "when" keeps that the natural reading order.
--   Samsung, 2 days: 42%
--   This Device: 19%
function JumpToast.message(opts)
    opts = opts or {}
    local label = opts.remote_label or _("Another device")

    local unit
    if type(opts.percent) == "number" then
        unit = string.format("%d%%", math.floor(opts.percent * 100 + 0.5))
    elseif type(opts.page) == "number" then
        unit = string.format(_("page %d"), opts.page)
    end

    local lines = {}
    if unit then
        local ago = JumpToast._relativeAgo(opts.timestamp) or _("<1 min")
        lines[#lines + 1] = string.format(_("%s, %s: %s"), label, ago, unit)
    else
        lines[#lines + 1] = string.format(_("%s is at a new position"), label)
    end

    local you_unit
    if type(opts.local_percent) == "number" then
        you_unit = string.format("%d%%", math.floor(opts.local_percent * 100 + 0.5))
    elseif type(opts.local_page) == "number" then
        you_unit = string.format(_("page %d"), opts.local_page)
    end
    if you_unit then
        -- No "when" here, unlike the peer line: your own position is
        -- definitionally now -- there is no other time it could be, so a
        -- time word here is pure noise, not information (unlike the peer's
        -- "when", which genuinely varies and is worth reading).
        lines[#lines + 1] = string.format(_("%s: %s"), _("This Device"), you_unit)
    end

    return table.concat(lines, "\n")
end


-- Pure: the cells of the two-column "here vs there" invite, as strings.
-- Returns { here_label, here_unit, here_chapter, peer_label, peer_unit,
-- peer_chapter, timestamp }.  Kept pure (no KOReader widgets) so the wording
-- stays unit-testable; buildContent below lays these out into aligned columns.
function JumpToast.fields(opts)
    opts = opts or {}
    -- Comparable unit: percent (reflowable) or page (paging docs).
    local function unit(percent, page)
        if type(percent) == "number" then
            return string.format("%d%%", math.floor(percent * 100 + 0.5))
        elseif type(page) == "number" then
            return string.format(_("page %d"), page)
        end
        return ""
    end
    local function chapter(c)
        if type(c) == "string" and c ~= "" then return c end
        -- No TOC title here -- the cover, front matter before the first titled
        -- chapter, or a document with no sections at all.  A neutral em dash
        -- fills the chapter slot (keeping both sides symmetric) without a label
        -- like "Beginning" that a sectionless or mid-gap position would falsify.
        return "—"
    end
    local timestamp = JumpToast._relativeAgo(opts.timestamp)
    return {
        here_label   = _("Here"),
        here_unit    = unit(opts.local_percent, opts.local_page),
        here_chapter = chapter(opts.local_chapter),
        peer_label   = opts.remote_label or _("Another device"),
        peer_unit    = unit(opts.percent, opts.page),
        peer_chapter = chapter(opts.chapter),
        timestamp    = timestamp,
    }
end


-- The "here vs there" comparison as a WIDGET.  `max_w` is the widest the
-- content may get (a screen fraction); the widget sizes ITSELF to the natural
-- (unwrapped) width of its longest line, capped at max_w -- so the dialog GROWS
-- to fit a long chapter title instead of over-wrapping in a fixed narrow box,
-- and stays compact for short ones.  Layout:
--   Here          3%
--   <our chapter>       (wraps within the chosen width)
--   (gap)
--   Kindle3WiFi   19% · 3h
--   <peer chapter>
-- The device NAME sits in a fixed-width column so the units line up vertically;
-- the unit (+ the peer's timestamp) follows, and the chapter gets its own
-- wrapping line below.  Returns (widget, content_w) so the caller can size the
-- dialog to the chosen width.  KOReader widgets required LAZILY so
-- message()/fields() stay unit-testable in a bare harness.
function JumpToast.buildContent(opts, max_w)
    local TextWidget      = require("ui/widget/textwidget")
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local Geom            = require("ui/geometry")
    local Font            = require("ui/font")
    local Size            = require("ui/size")

    local f    = JumpToast.fields(opts)
    local face = Font:getFace("infofont")
    local gap  = Size.span.horizontal_default

    -- Cap the name column: peer_label is a user-chosen device name and can be
    -- arbitrarily long; without the cap the head row overflows max_w/the screen
    -- and pushes the percent off both edges.  TextWidget truncates with "…".
    local NAME_FRAC = 0.4
    local name_cap  = math.floor(max_w * NAME_FRAC)
    local n_here = TextWidget:new{ text = f.here_label, face = face, bold = true, max_width = name_cap }
    local n_peer = TextWidget:new{ text = f.peer_label, face = face, bold = true, max_width = name_cap }
    local name_w = math.min(math.max(n_here:getSize().w, n_peer:getSize().w), name_cap)
    local name_h = math.max(n_here:getSize().h, n_peer:getSize().h)

    local function value_str(unit, ts)
        local parts = {}
        if unit ~= "" then parts[#parts + 1] = unit end
        if ts then parts[#parts + 1] = ts end
        return table.concat(parts, " · ")
    end
    local here_val = value_str(f.here_unit, nil)
    local peer_val = value_str(f.peer_unit, f.timestamp)

    -- Natural (unwrapped) width of the widest line -> grow-to-fit width.
    local function natural_w(s)
        if s == "" then return 0 end
        local t = TextWidget:new{ text = s, face = face }
        local w = t:getSize().w
        t:free()
        return w
    end
    local natural = math.max(
        name_w + gap + natural_w(here_val),
        name_w + gap + natural_w(peer_val),
        natural_w(f.here_chapter),
        natural_w(f.peer_chapter))
    local content_w = math.min(natural, max_w)
    -- name_w capped to name_cap, so the value column keeps the rest (no floor).
    local value_w = content_w - name_w - gap

    -- One side = a name/unit head row (name in a fixed cell so units align)
    -- plus the chapter on its own wrapping line.
    local function side(name_tw, unit, ts, chapter)
        local rows = { align = "left",
            HorizontalGroup:new{
                align = "top",
                LeftContainer:new{ dimen = Geom:new{ w = name_w, h = name_h }, name_tw },
                HorizontalSpan:new{ width = gap },
                TextBoxWidget:new{ text = value_str(unit, ts), face = face, width = value_w },
            },
        }
        if chapter ~= "" then
            table.insert(rows,
                TextBoxWidget:new{ text = chapter, face = face, width = content_w })
        end
        return VerticalGroup:new(rows)
    end

    local group = VerticalGroup:new{
        align = "left",
        side(n_here, f.here_unit, nil, f.here_chapter),
        VerticalSpan:new{ width = Size.padding.large },
        side(n_peer, f.peer_unit, f.timestamp, f.peer_chapter),
    }
    return group, content_w
end


-- The two-line touch-bar version: BOLD, guaranteed bounded (never wraps),
-- with an INVERTED (white-on-black) badge around the peer's recency bucket
-- -- the one thing that actually decides whether a jump is worth it (see
-- jump_policy.lua: "forward means newer, not necessarily ahead in the
-- document" -- a prompt exists at all only because the peer is NEWER, not
-- because it is further along).
--   Samsung, [2 days]: 42%
--   This Device: 19%
-- Each row is split into pieces, not one flat string: the device NAME
-- (unbounded -- user-chosen, can be arbitrarily long) gets whatever width is
-- left after the badge + the ": <what>" suffix (both short, fixed-length) --
-- so the suffix, specifically the percent/page (the actual navigational
-- target: where you'd land), is NEVER truncated away, whatever the name's
-- length. An earlier, simpler version capped the WHOLE line in one
-- TextWidget and truncated the percent itself away entirely for a long
-- device name -- confirmed on-device ("KindlePaperWhite6, just now…" with
-- the percent silently gone); this split is the fix, not a style choice.
-- "This Device" carries no badge -- its own position has no comparable
-- "when" (always now), so nothing there needs highlighting. Returns
-- (widget, content_w), same shape as buildContent above.
function JumpToast.buildTouchContent(opts, max_w)
    local TextWidget      = require("ui/widget/textwidget")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Blitbuffer      = require("ffi/blitbuffer")
    local Font            = require("ui/font")
    local Size            = require("ui/size")

    opts = opts or {}
    local face = Font:getFace("infofont")
    local gap  = Size.span.horizontal_default

    local function badge(text)
        local badge_tw = TextWidget:new{
            text = text, face = face, bold = true, fgcolor = Blitbuffer.COLOR_WHITE,
        }
        return FrameContainer:new{
            background     = Blitbuffer.COLOR_BLACK,
            bordersize     = 0,
            margin         = 0,
            padding_top    = Size.padding.small,
            padding_bottom = Size.padding.small,
            padding_left   = Size.padding.default,
            padding_right  = Size.padding.default,
            badge_tw,
        }
    end

    local peer_label = opts.remote_label or _("Another device")
    local unit
    if type(opts.percent) == "number" then
        unit = string.format("%d%%", math.floor(opts.percent * 100 + 0.5))
    elseif type(opts.page) == "number" then
        unit = string.format(_("page %d"), opts.page)
    end

    local rows = { align = "left" }
    local content_w = 0

    if unit then
        local ago_bucket = JumpToast._relativeAgo(opts.timestamp) or _("<1 min")
        local ago_badge  = badge(ago_bucket)
        local suffix_tw  = TextWidget:new{ text = string.format(_(": %s"), unit), face = face, bold = true }
        local reserved   = ago_badge:getSize().w + gap + suffix_tw:getSize().w
        local name_w     = math.max(0, max_w - reserved)
        local name_tw    = TextWidget:new{ text = peer_label .. ",", face = face, bold = true, max_width = name_w }
        local peer_row = HorizontalGroup:new{
            align = "center",
            name_tw, HorizontalSpan:new{ width = gap }, ago_badge, suffix_tw,
        }
        content_w = math.max(content_w, peer_row:getSize().w)
        table.insert(rows, peer_row)
    else
        local single = TextWidget:new{
            text = string.format(_("%s is at a new position"), peer_label),
            face = face, bold = true, max_width = max_w,
        }
        content_w = math.max(content_w, single:getSize().w)
        table.insert(rows, single)
    end

    local you_unit
    if type(opts.local_percent) == "number" then
        you_unit = string.format("%d%%", math.floor(opts.local_percent * 100 + 0.5))
    elseif type(opts.local_page) == "number" then
        you_unit = string.format(_("page %d"), opts.local_page)
    end
    if you_unit then
        table.insert(rows, VerticalSpan:new{ width = Size.padding.small })
        -- No badge, no "when" here, unlike the peer row -- your own
        -- position is definitionally now, nothing to highlight or say.
        local you_tw = TextWidget:new{
            text = string.format(_("%s: %s"), _("This Device"), you_unit),
            face = face, bold = true, max_width = max_w,
        }
        content_w = math.max(content_w, you_tw:getSize().w)
        table.insert(rows, you_tw)
    end

    return VerticalGroup:new(rows), content_w
end


-- The action button label.
function JumpToast.actionLabel()
    return _("Jump")
end


return JumpToast
