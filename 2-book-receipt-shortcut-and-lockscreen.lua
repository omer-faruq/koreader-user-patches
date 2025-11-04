--[[
    Book Receipt - KOReader User Patch
    
    This user patch displays reading progress in a visual "receipt" format.
    
    Features:
    - Can be triggered via the Dispatcher shortcut `book_receipt`
    - Can be set as screensaver/sleep screen
    - When added as wallpaper, it provides background color options (white/black/transparent)
    
    Original code created by Reddit user hundredpercentcocoa
    https://www.reddit.com/user/hundredpercentcocoa/
    
    Modifications in this fork:
    - Added wallpaper/screensaver integration with background color options
    - Added book cover display in the receipt
    
    Fork: https://github.com/omer-faruq/koreader-user-patches
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local ReaderUI = require("apps/reader/readerui")
local RenderImage = require("ui/renderimage")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local bit = require("bit")
local datetime = require("datetime")
local logger = require("logger")
local util = require("util")
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local Screen = Device.screen 
local T = ffiUtil.template
local BOOK_RECEIPT_BG_SETTING = "book_receipt_screensaver_background"

local function getReceiptBackgroundColor()
    local choice = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING) or "white"
    if choice == "transparent" then
        return nil
    elseif choice == "black" then
        return Blitbuffer.COLOR_BLACK
    end
    return Blitbuffer.COLOR_WHITE
end

local function hasActiveDocument(ui)
    return ui and ui.document ~= nil
end

local function getBookReceiptFallbackType()
    local random_dir = G_reader_settings:readSetting("screensaver_dir")
    if random_dir and lfs.attributes(random_dir, "mode") == "directory" then
        return "random_image"
    end

    local document_cover = G_reader_settings:readSetting("screensaver_document_cover")
    if document_cover and lfs.attributes(document_cover, "mode") == "file" then
        return "document_cover"
    end

    local lastfile = G_reader_settings:readSetting("lastfile")
    if lastfile and lfs.attributes(lastfile, "mode") == "file" then
        return "cover"
    end

    return "random_image"
end

local function getEventFromPrefix(prefix)
    if prefix and prefix ~= "" then
        return prefix:sub(1, -2)
    end
    return nil
end

local function showFallbackScreensaver(self, orig_show)
    local fallback_type = getBookReceiptFallbackType()
    logger.dbg("Book receipt: using fallback screensaver", fallback_type)

    local original_type = self.screensaver_type
    local event = getEventFromPrefix(self.prefix)

    local settings = G_reader_settings
    local primary_key = "screensaver_type"
    local had_primary = settings:has(primary_key)
    local original_primary = settings:readSetting(primary_key)
    settings:saveSetting(primary_key, fallback_type)

    local prefixed_key = self.prefix and self.prefix ~= "" and (self.prefix .. "screensaver_type") or nil
    local had_prefixed, original_prefixed
    if prefixed_key then
        had_prefixed = settings:has(prefixed_key)
        original_prefixed = settings:readSetting(prefixed_key)
        settings:saveSetting(prefixed_key, fallback_type)
    end

    self:setup(event, self.event_message)
    self.screensaver_type = fallback_type
    orig_show(self)

    if prefixed_key then
        if had_prefixed then
            settings:saveSetting(prefixed_key, original_prefixed)
        else
            settings:delSetting(prefixed_key)
        end
    end

    if had_primary then
        settings:saveSetting(primary_key, original_primary)
    else
        settings:delSetting(primary_key)
    end

    self.screensaver_type = original_type
end

local function buildReceipt(ui, state)
    if not hasActiveDocument(ui) then return nil end

    local doc_props = ui.doc_props or {}
    local book_title = doc_props.display_title or ""
    local book_author = doc_props.authors or ""
    if book_author:find("\n") then
        local authors = util.splitToArray(book_author, "\n")
        if authors and authors[1] then
            book_author = T(_("%1 et al."), authors[1] .. ",")
        end
    end

    local doc_settings = ui.doc_settings and ui.doc_settings.data or {}
    local page_no = (state and state.page) or 1
    local page_total = doc_settings.doc_pages or 1
    if page_total <= 0 then page_total = 1 end
    if page_no < 1 then page_no = 1 end
    if page_no > page_total then page_no = page_total end

    local page_left = math.max(page_total - page_no, 0)
    local toc = ui.toc
    local chapter_title = ""
    local chapter_total = page_total
    local chapter_left = 0
    local chapter_done = 0
    if toc then
        chapter_title = toc:getTocTitleByPage(page_no) or ""
        chapter_total = toc:getChapterPageCount(page_no) or chapter_total
        chapter_left = toc:getChapterPagesLeft(page_no) or 0
        chapter_done = toc:getChapterPagesDone(page_no) or 0
    end
    chapter_total = chapter_total > 0 and chapter_total or page_total
    chapter_done = math.max(chapter_done + 1, 1)

    local statistics = ui.statistics
    local avg_time_per_page = statistics and statistics.avg_time
    local function secs_to_timestring(secs)
        if not secs then return "calculating time" end
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        local htext = h == 1 and "hr" or "hrs"
        local mtext = m == 1 and "min" or "mins"
        if h == 0 and m > 0 then
            return string.format("%i %s", m, mtext)
        elseif h > 0 and m == 0 then
            return string.format("%i %s", h, htext)
        elseif h > 0 and m > 0 then
            return string.format("%i %s %i %s", h, htext, m, mtext)
        elseif h == 0 and m == 0 then
            return "less than a minute"
        end
        return "calculating time"
    end
    local function time_left(pages)
        if not avg_time_per_page then return nil end
        return avg_time_per_page * pages
    end

    local book_time_left = secs_to_timestring(time_left(page_left))
    local chapter_time_left = secs_to_timestring(time_left(chapter_left))

    local current_time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) or ""

    local battery = ""
    if Device:hasBattery() then
        local power_dev = Device:getPowerDevice()
        local batt_lvl = power_dev:getCapacity() or 0
        local is_charging = power_dev:isCharging() or false
        local batt_prefix = power_dev:getBatterySymbol(power_dev:isCharged(), is_charging, batt_lvl) or ""
        battery = batt_prefix .. batt_lvl .. "%"
    end

    local widget_width = Screen:getWidth() / 2
    local db_font_color = Blitbuffer.COLOR_BLACK
    local db_font_color_lighter = Blitbuffer.COLOR_GRAY_3
    local db_font_color_lightest = Blitbuffer.COLOR_GRAY_9
    local db_font_face = "NotoSans-Regular.ttf"
    local db_font_face_italics = "NotoSans-Italic.ttf"
    local db_font_size_big = 25
    local db_font_size_mid = 18
    local db_font_size_small = 15
    local db_padding = 20
    local db_padding_internal = 8

    local function databox(typename, itemname, pages_done, pages_total, time_left_text)
        local denom = pages_total > 0 and pages_total or 1
        local percentage_value = math.max(math.min(pages_done / denom, 1), 0)

        local boxtitle = TextWidget:new{
            text = typename,
            face = Font:getFace("cfont", db_font_size_big),
            bold = true,
            fgcolor = db_font_color,
            padding = 0,
        }

        local item_name_widget = TextBoxWidget:new{
            face = Font:getFace(db_font_face, db_font_size_mid),
            text = itemname,
            width = widget_width,
            fgcolor = db_font_color,
        }

        local progressbarwidth = widget_width
        local progress_bar = ProgressWidget:new{
            width = progressbarwidth,
            height = Screen:scaleBySize(2),
            percentage = percentage_value,
            margin_v = 0,
            margin_h = 0,
            radius = 20,
            bordersize = 0,
            bgcolor = db_font_color_lightest,
            fillcolor = db_font_color,
        }

        local page_progress = TextWidget:new{
            text = string.format("page %i of %i", pages_done, pages_total),
            face = Font:getFace("cfont", db_font_size_small),
            bold = false,
            fgcolor = db_font_color_lighter,
            padding = 0,
            align = "left",
        }

        local percentage_display = TextWidget:new{
            text = string.format("%i%%", math.floor(percentage_value * 100 + 0.5)),
            face = Font:getFace("cfont", db_font_size_small),
            bold = false,
            fgcolor = db_font_color_lighter,
            padding = 0,
            align = "right",
        }

        local progressmodule = VerticalGroup:new{
            progress_bar,
            HorizontalGroup:new{
                page_progress,
                HorizontalSpan:new{ width = progressbarwidth - page_progress:getSize().w - percentage_display:getSize().w },
                percentage_display,
            },
        }

        local time_left_display = TextWidget:new{
            text = string.format("%s left in %s", time_left_text, typename),
            face = Font:getFace(db_font_face_italics, db_font_size_small),
            bold = false,
            fgcolor = db_font_color,
            padding = 0,
            align = "right",
        }

        return VerticalGroup:new{
            boxtitle,
            VerticalSpan:new{ width = db_padding_internal },
            item_name_widget,
            VerticalSpan:new{ width = db_padding_internal },
            progressmodule,
            VerticalSpan:new{ width = db_padding_internal },
            time_left_display,
            VerticalSpan:new{ width = db_padding_internal },
        }
    end

    local batt_pct_box = TextWidget:new{
        text = battery,
        face = Font:getFace("cfont", db_font_size_small),
        bold = false,
        fgcolor = db_font_color,
        padding = 0,
    }

    local glyph_clock = "⌚"
    local time_box = TextWidget:new{
        text = string.format("%s%s", glyph_clock, current_time),
        face = Font:getFace("cfont", db_font_size_small),
        bold = false,
        fgcolor = db_font_color,
        padding = 0,
    }

    local bottom_bar = HorizontalGroup:new{
        batt_pct_box,
        HorizontalSpan:new{ width = widget_width - time_box:getSize().w - batt_pct_box:getSize().w },
        time_box,
    }

    local bookboxtitle = string.format("%s - %s", book_title, book_author)
    local bookbox = databox("Book", bookboxtitle, page_no, page_total, book_time_left)
    local chapterbox = databox("Chapter", chapter_title, chapter_done, chapter_total, chapter_time_left)

    local cover_widget
    if ui.bookinfo and ui.document then
        local cover_bb = ui.bookinfo:getCoverImage(ui.document)
        if cover_bb then
            local cover_width = cover_bb:getWidth()
            local cover_height = cover_bb:getHeight()
            local max_width = widget_width
            local max_height = math.floor(Screen:getHeight() / 3)
            local scale = math.min(1, max_width / cover_width, max_height / cover_height)
            if scale < 1 then
                local scaled_w = math.max(1, math.floor(cover_width * scale))
                local scaled_h = math.max(1, math.floor(cover_height * scale))
                cover_bb = RenderImage:scaleBlitBuffer(cover_bb, scaled_w, scaled_h, true)
                cover_width = cover_bb:getWidth()
                cover_height = cover_bb:getHeight()
            end
            cover_widget = CenterContainer:new{
                dimen = Geom:new{ w = widget_width, h = cover_height },
                ImageWidget:new{ image = cover_bb, width = cover_width, height = cover_height },
            }
        end
    end

    local content_children = {}
    if cover_widget then
        table.insert(content_children, cover_widget)
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
    end
    table.insert(content_children, chapterbox)
    table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
    table.insert(content_children, bookbox)
    table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
    table.insert(content_children, bottom_bar)

    local final_frame = FrameContainer:new{
        radius = 15,
        bordersize = 2,
        padding_top = math.floor(db_padding / 2),
        padding_right = db_padding,
        padding_bottom = db_padding,
        padding_left = db_padding,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new(content_children),
    }

    return CenterContainer:new{
        dimen = Screen:getSize(),
        final_frame,
    }
end

local quicklookbox = InputContainer:extend{  
    modal = true,  
    name = "quick_look_box",  
}  

function quicklookbox:init()
    local receipt_widget = buildReceipt(self.ui, self.state)
    if receipt_widget then
        self[1] = receipt_widget
    else
        logger.warn("Book receipt: failed to build quick look widget")
        self[1] = CenterContainer:new{
            dimen = Screen:getSize(),
            TextWidget:new{
                text = _("Receipt unavailable"),
                face = Font:getFace("cfont", 20),
            },
        }
    end

    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function() return self.dimen end,
            }
        }
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.dimen end,
            }
        }
        self.ges_events.MultiSwipe = {
            GestureRange:new{
                ges = "multiswipe",
                range = function() return self.dimen end,
            }
        }
    end
end

function quicklookbox:onTap()
    UIManager:close(self)
end

function quicklookbox:onSwipe(arg, ges_ev)
    if ges_ev.direction == "south" then
        -- Allow easier closing with swipe up/down
        self:onClose()
    elseif ges_ev.direction == "east" or ges_ev.direction == "west" or ges_ev.direction == "north" then
        self:onClose()-- -- no use for now
        -- do end -- luacheck: ignore 541
    else -- diagonal swipe
		self:onClose()

    end
end

function quicklookbox:onClose()
    UIManager:close(self)
    return true
end

quicklookbox.onAnyKeyPressed = quicklookbox.onClose

quicklookbox.onMultiSwipe = quicklookbox.onClose

-- add to dispatcher

Dispatcher:registerAction("quicklookbox_action", {
							category="none", 
							event="QuickLook", 
							title=_("Book receipt"), 
							reader=true,})

function ReaderUI:onQuickLook()
    local widget = quicklookbox:new{
        ui = self,
        document = self.document,
        state = self.view and self.view.state,
    }
    UIManager:show(widget)
end

-- Screensaver integration

local Screensaver = require("ui/screensaver")

local orig_screensaver_show = Screensaver.show

Screensaver.show = function(self)
    if self.screensaver_type == "book_receipt" then
        logger.dbg("Book receipt: screensaver activated")

        if self.screensaver_widget then
            UIManager:close(self.screensaver_widget)
            self.screensaver_widget = nil
        end

        Device.screen_saver_mode = true

        local rotation_mode = Screen:getRotationMode()
        Device.orig_rotation_mode = rotation_mode
        if bit.band(rotation_mode, 1) == 1 then
            Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        else
            Device.orig_rotation_mode = nil
        end

        local ui = self.ui or ReaderUI.instance
        local state = ui and ui.view and ui.view.state
        local receipt_widget = buildReceipt(ui, state)

        if receipt_widget then
            local background_color = getReceiptBackgroundColor()
            self.screensaver_widget = ScreenSaverWidget:new{
                widget = receipt_widget,
                background = background_color,
                covers_fullscreen = true,
            }
            self.screensaver_widget.modal = true
            self.screensaver_widget.dithered = true
            UIManager:show(self.screensaver_widget, "full")
        else
            logger.warn("Book receipt: failed to build widget, falling back to default screensaver")
            showFallbackScreensaver(self, orig_screensaver_show)
        end

        return
    end

    logger.dbg("Book receipt: no active document, using fallback screensaver")
    showFallbackScreensaver(self, orig_screensaver_show)
end

-- Add screensaver menu option

local orig_dofile = dofile

_G.dofile = function(filepath)
    local result = orig_dofile(filepath)

    if filepath and filepath:match("screensaver_menu%.lua$") then
        logger.dbg("Book receipt: patching screensaver menu")

        if result and result[1] and result[1].sub_item_table then
            local wallpaper_submenu = result[1].sub_item_table

            local function genMenuItem(text, setting, value, enabled_func, separator)
                return {
                    text = text,
                    enabled_func = enabled_func,
                    checked_func = function()
                        return G_reader_settings:readSetting(setting) == value
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(setting, value)
                    end,
                    radio = true,
                    separator = separator,
                }
            end

            table.insert(wallpaper_submenu, 6,
                genMenuItem(_("Show book receipt on sleep screen"), "screensaver_type", "book_receipt")
            )

            table.insert(wallpaper_submenu, 7, {
                text = _("Book receipt background"),
                enabled_func = function()
                    return G_reader_settings:readSetting("screensaver_type") == "book_receipt"
                end,
                sub_item_table = {
                    genMenuItem(_("White fill"), BOOK_RECEIPT_BG_SETTING, "white"),
                    genMenuItem(_("Transparent"), BOOK_RECEIPT_BG_SETTING, "transparent"),
                    genMenuItem(_("Black fill"), BOOK_RECEIPT_BG_SETTING, "black"),
                },
            })
        end
    end

    return result
end

