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


local JumpToast = {}


-- The invitation message. `opts`:
--   remote_label  string|nil  device name (defaults to "Another device")
--   percent       number|nil  fraction 0..1 -- the cross-device-stable unit
--   chapter       string|nil  resolved chapter title (from the shared font-
--                             independent xpointer); shown only alongside
--                             percent, as the human anchor
--   page          number|nil  a FIXED page number -- only for paging docs
--                             (PDF/CBZ), where pages coincide across devices
--   timestamp     number|nil  when the remote device was there (unix)
--   local_percent number|nil  THIS device's current fraction 0..1
--   local_page    number|nil  THIS device's current page (paging docs)
--
-- The remote device's stored PAGE is device-LOCAL for reflowable books (each
-- device re-lays-out the text with its own font/screen), so it is never shown
-- for them -- the caller passes `percent` (+ resolved `chapter`) instead, and
-- passes `page` only for paging docs whose pages are identical everywhere.
--
-- A jump is a from -> to decision: the second line shows WHEN the peer was
-- there and where the reader is NOW, so "Jump or Stay" is answerable without
-- opening the progress browser first (field request).
function JumpToast.message(opts)
    opts = opts or {}
    local label = opts.remote_label or _("Another device")
    local head
    -- Reflowable (EPUB): percent is comparable across devices; the resolved
    -- chapter is the meaningful anchor when available.
    if type(opts.percent) == "number" then
        local pct = math.floor(opts.percent * 100 + 0.5)
        if type(opts.chapter) == "string" and opts.chapter ~= "" then
            head = string.format(_("%s is at %d%% — %s"), label, pct, opts.chapter)
        else
            head = string.format(_("%s is at %d%%"), label, pct)
        end
    -- Paging (PDF/CBZ): the page is fixed across devices, so it is the natural
    -- stable unit; the caller passes it only for these docs.
    elseif type(opts.page) == "number" then
        head = string.format(_("%s is on page %d"), label, opts.page)
    else
        head = string.format(_("%s is at a new position"), label)
    end

    local ctx = {}
    if type(opts.timestamp) == "number" and opts.timestamp > 0 then
        -- Numeric ISO-ish date: locale-neutral, no month-name i18n.
        ctx[#ctx + 1] = os.date("%Y-%m-%d %H:%M", opts.timestamp)
    end
    if type(opts.local_percent) == "number" then
        ctx[#ctx + 1] = string.format(_("you are at %d%%"),
            math.floor(opts.local_percent * 100 + 0.5))
    elseif type(opts.local_page) == "number" then
        ctx[#ctx + 1] = string.format(_("you are on page %d"), opts.local_page)
    end
    if #ctx > 0 then
        head = head .. "\n" .. table.concat(ctx, " · ")
    end
    return head
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
    local timestamp
    if type(opts.timestamp) == "number" and opts.timestamp > 0 then
        -- Numeric ISO-ish date: locale-neutral, no month-name i18n.
        timestamp = os.date("%Y-%m-%d %H:%M", opts.timestamp)
    end
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
--   Kindle3WiFi   19% · 2026-07-05 03:30
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


-- The action button label.
function JumpToast.actionLabel()
    return _("Jump")
end


return JumpToast
