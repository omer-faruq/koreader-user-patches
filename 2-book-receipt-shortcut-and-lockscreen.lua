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
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local ReaderUI = require("apps/reader/readerui")
local RenderImage = require("ui/renderimage")
local OverlapGroup = require("ui/widget/overlapgroup")
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
local SQ3 = require("lua-ljsqlite3/init")
local _ = require("gettext")

local Screen = Device.screen 
local T = ffiUtil.template
local BOOK_RECEIPT_BG_SETTING = "book_receipt_screensaver_background"
local BOOK_RECEIPT_BG_IMAGE_MODE_SETTING = "book_receipt_bg_image_mode"
local BOOK_RECEIPT_CONTENT_MODE_SETTING = "book_receipt_content_mode"

local MAX_HIGHLIGHT_SIZE = 500
local HIDE_COVER_FOR_LARGE_HIGHLIGHTS = 300
local BOOK_RECEIPT_COVER_SCALE = 1
local STATISTICS_DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local CONTENT_MODE_BOOK_RECEIPT = "book_receipt"
local CONTENT_MODE_HIGHLIGHT_PROGRESS = "highlight_progress"
local CONTENT_MODE_RANDOM = "random"

local function utf8TrimToLength(str, max_chars)
    if not str or max_chars <= 0 then
        return "", 0, str ~= nil and str ~= ""
    end
    local len = #str
    local index = 1
    local char_count = 0
    local cut_index
    while index <= len do
        local byte = string.byte(str, index)
        if not byte then break end
        local char_len = 1
        if byte >= 0xF0 then
            char_len = 4
        elseif byte >= 0xE0 then
            char_len = 3
        elseif byte >= 0xC0 then
            char_len = 2
        end
        char_count = char_count + 1
        index = index + char_len
        if not cut_index and char_count == max_chars + 1 then
            cut_index = index - char_len
        end
    end
    if cut_index then
        return str:sub(1, cut_index - 1), char_count, true
    end
    return str, char_count, false
end

local function getLocalizedDayName(timestamp)
    local day_key = timestamp and os.date("%A", timestamp)
    if not day_key then
        return ""
    end
    if datetime and datetime.longDayTranslation and datetime.longDayTranslation[day_key] then
        return datetime.longDayTranslation[day_key]
    end
    return day_key
end

local function getBookTodayDuration(statistics)
    if not statistics then
        return nil
    end

    if statistics.isEnabled and not statistics:isEnabled() then
        return nil
    end

    if statistics.insertDB then
        pcall(statistics.insertDB, statistics)
    end

    local id_book = statistics.id_curr_book
    if (not id_book) and statistics.getIdBookDB then
        local ok, book_id = pcall(statistics.getIdBookDB, statistics)
        if ok then
            id_book = book_id
        end
    end
    if not id_book then
        return nil
    end

    if not STATISTICS_DB_PATH or STATISTICS_DB_PATH == "" then
        return nil
    end

    local attrs = lfs.attributes(STATISTICS_DB_PATH, "mode")
    if attrs ~= "file" then
        return nil
    end

    local now_stamp = os.time()
    local now_t = os.date("*t", now_stamp)
    local from_begin_day = now_t.hour * 3600 + now_t.min * 60 + now_t.sec
    local start_today_time = now_stamp - from_begin_day

    local ok_conn, conn = pcall(SQ3.open, STATISTICS_DB_PATH)
    if not ok_conn or not conn then
        return nil
    end

    local sql_stmt = string.format([[SELECT sum(sum_duration)
        FROM (
            SELECT sum(duration) AS sum_duration
            FROM page_stat
            WHERE start_time >= %d AND id_book = %d
            GROUP BY page
        );
    ]], start_today_time, id_book)

    local ok_row, today_duration = pcall(function()
        return conn:rowexec(sql_stmt)
    end)
    conn:close()

    if not ok_row or today_duration == nil then
        return nil
    end

    today_duration = tonumber(today_duration)
    if not today_duration then
        return nil
    end

    if today_duration < 0 then
        today_duration = 0
    end
    return today_duration
end

local function getRandomHighlightAnnotation(ui)
    if not ui or not ui.annotation or not ui.annotation.annotations then
        return nil
    end
    local candidates = {}
    for _, item in ipairs(ui.annotation.annotations) do
        if item.drawer and item.text then
            local trimmed = util.trim(item.text)
            if trimmed ~= "" then
                table.insert(candidates, item)
            end
        end
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[math.random(#candidates)]
end

local function getBookReceiptBackgroundDir()
    local base_dir = DataStorage:getDataDir()
    if not base_dir or base_dir == "" then
        return nil
    end
    return string.format("%s/%s", base_dir, "book_receipt_background")
end

local function pickRandomReceiptBackgroundImage()
    local dir = getBookReceiptBackgroundDir()
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then
        return nil
    end

    local files = {}
    util.findFiles(dir, function(file)
        if not util.stringStartsWith(ffiUtil.basename(file), "._") and DocumentRegistry:isImageFile(file) then
            table.insert(files, file)
        end
    end, false, 512)

    if #files == 0 then
        return nil
    end
    return files[math.random(#files)]
end

local function buildBackgroundImageWidget(image_source)
    if not image_source then
        return nil
    end

    local mode = G_reader_settings:readSetting(BOOK_RECEIPT_BG_IMAGE_MODE_SETTING) or "stretch"
    if mode ~= "center" and mode ~= "stretch" and mode ~= "fit" then
        mode = "stretch"
    end

    local screen_size = Screen:getSize()
    local screen_w, screen_h = screen_size.w, screen_size.h
    local image_opts = {
        alpha = true,
        file_do_cache = false,
    }

    if type(image_source) == "string" then
        image_opts.file = image_source
    else
        image_opts.image = image_source
    end

    if mode == "stretch" then
        image_opts.width = screen_w
        image_opts.height = screen_h
    elseif mode == "fit" then
        image_opts.width = screen_w
        image_opts.height = screen_h
        image_opts.scale_factor = 0
    end

    local image_widget = ImageWidget:new(image_opts)

    if mode == "center" then
        return CenterContainer:new{
            dimen = screen_size,
            image_widget,
        }
    end

    return image_widget
end

local function getActiveDocumentCover(ui)
    if not ui or not ui.document or not ui.bookinfo then
        return nil
    end
    return ui.bookinfo:getCoverImage(ui.document)
end

local function getReceiptBackground(ui)
    local choice = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING) or "white"

    if choice == "transparent" then
        return nil, nil
    elseif choice == "black" then
        return Blitbuffer.COLOR_BLACK, nil
    elseif choice == "random_image" then
        local image_path = pickRandomReceiptBackgroundImage()
        if image_path then
            local widget = buildBackgroundImageWidget(image_path)
            if widget then
                return nil, widget
            end
        end
        return nil, nil
    elseif choice == "book_cover" then
        local cover_bb = getActiveDocumentCover(ui)
        if cover_bb then
            local widget = buildBackgroundImageWidget(cover_bb)
            if widget then
                return nil, widget
            end
        end
        return nil, nil
    end

    return Blitbuffer.COLOR_WHITE, nil
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
    local doc_page_no = (state and state.page) or 1
    local doc_page_total = doc_settings.doc_pages or 1
    if doc_page_total <= 0 then doc_page_total = 1 end
    if doc_page_no < 1 then doc_page_no = 1 end
    if doc_page_no > doc_page_total then doc_page_no = doc_page_total end

    local page_no_numeric = doc_page_no
    local page_total_numeric = doc_page_total
    local page_no_display = tostring(page_no_numeric)
    local page_total_display = tostring(page_total_numeric)

    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        local label, idx, count = ui.pagemap:getCurrentPageLabel(true)
        local last_label = ui.pagemap:getLastPageLabel(true)
        if idx and count then
            page_no_numeric = idx
            page_total_numeric = count
        end
        if label and label ~= "" then
            page_no_display = label
        else
            page_no_display = tostring(page_no_numeric)
        end
        if last_label and last_label ~= "" then
            page_total_display = last_label
        else
            page_total_display = tostring(page_total_numeric)
        end
    end

    local page_left = math.max(page_total_numeric - page_no_numeric, 0)
    local toc = ui.toc
    local chapter_title = ""
    local chapter_total = page_total_numeric
    local chapter_left = 0
    local chapter_done = 0
    if toc then
        chapter_title = toc:getTocTitleByPage(doc_page_no) or ""
        chapter_total = toc:getChapterPageCount(doc_page_no) or chapter_total
        chapter_left = toc:getChapterPagesLeft(doc_page_no) or 0
        chapter_done = toc:getChapterPagesDone(doc_page_no) or 0
    end
    chapter_total = chapter_total > 0 and chapter_total or page_total_numeric
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

    local message_text
    if Device.screen_saver_mode and G_reader_settings:isTrue("screensaver_show_message") then
        local configured_message = G_reader_settings:readSetting("screensaver_message")
        configured_message = configured_message and util.trim(configured_message)
        if configured_message and configured_message ~= "" then
            if ui and ui.bookinfo and ui.bookinfo.expandString then
                message_text = ui.bookinfo:expandString(configured_message) or configured_message
            else
                message_text = configured_message
            end
            if message_text then
                message_text = util.trim(message_text)
                if message_text == "" then
                    message_text = nil
                end
            end
        end
    end

    local function databox(typename, itemname, pages_done, pages_total, time_left_text, pages_done_display, pages_total_display, options)
        options = options or {}
        local pages_done_num = tonumber(pages_done) or 0
        local pages_total_num = tonumber(pages_total) or 0
        local denom = pages_total_num > 0 and pages_total_num or 1
        local percentage_value = math.max(math.min(pages_done_num / denom, 1), 0)
        local display_done = pages_done_display or pages_done
        local display_total = pages_total_display or pages_total

        local elements = {}
        if not options.hide_title then
            table.insert(elements, TextWidget:new{
                text = typename,
                face = Font:getFace("cfont", db_font_size_big),
                bold = true,
                fgcolor = db_font_color,
                padding = 0,
            })
            table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
        end

        table.insert(elements, TextBoxWidget:new{
            face = Font:getFace(db_font_face, db_font_size_mid),
            text = itemname,
            width = widget_width,
            fgcolor = db_font_color,
        })

        local progressbarwidth = widget_width
        local progress_bar = ProgressWidget:new{
            width = progressbarwidth,
            height = Screen:scaleBySize(5),
            percentage = percentage_value,
            margin_v = 0,
            margin_h = 0,
            radius = 20,
            bordersize = 0,
            bgcolor = db_font_color_lightest,
            fillcolor = db_font_color,
        }

        local page_progress = TextWidget:new{
            text = string.format("page %s of %s", display_done, display_total),
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

        table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
        table.insert(elements, VerticalGroup:new{
            progress_bar,
            HorizontalGroup:new{
                page_progress,
                HorizontalSpan:new{ width = progressbarwidth - page_progress:getSize().w - percentage_display:getSize().w },
                percentage_display,
            },
        })

        if not options.hide_time and time_left_text then
            table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
            table.insert(elements, TextWidget:new{
                text = string.format("%s left in %s", time_left_text, typename),
                face = Font:getFace(db_font_face_italics, db_font_size_small),
                bold = false,
                fgcolor = db_font_color,
                padding = 0,
                align = "right",
            })
        end

        if options.total_time_text then
            table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
            table.insert(elements, TextWidget:new{
                text = options.total_time_text,
                face = Font:getFace(db_font_face_italics, db_font_size_small),
                bold = false,
                fgcolor = db_font_color,
                padding = 0,
                align = "right",
            })
        end

        if options.today_time_text then
            table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
            table.insert(elements, TextWidget:new{
                text = options.today_time_text,
                face = Font:getFace(db_font_face_italics, db_font_size_small),
                bold = false,
                fgcolor = db_font_color,
                padding = 0,
                align = "right",
            })
        end

        table.insert(elements, VerticalSpan:new{ width = db_padding_internal })

        return VerticalGroup:new(elements)
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
    local content_mode_setting = G_reader_settings:readSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING) or CONTENT_MODE_BOOK_RECEIPT
    local content_mode = content_mode_setting
    if content_mode_setting == CONTENT_MODE_RANDOM then
        local candidates = { CONTENT_MODE_BOOK_RECEIPT, CONTENT_MODE_HIGHLIGHT_PROGRESS }
        content_mode = candidates[math.random(#candidates)]
    end
    local book_total_time_text
    local book_today_time_text
    if statistics and content_mode ~= CONTENT_MODE_HIGHLIGHT_PROGRESS then
        book_total_time_text = string.format("Total time spent: %s", secs_to_timestring(statistics.book_read_time))
        local today_duration = getBookTodayDuration(statistics)
        if today_duration then
            local day_label = getLocalizedDayName(os.time())
            book_today_time_text = string.format("Time spent today (%s): %s", day_label, secs_to_timestring(today_duration))
        end
    end

    local bookbox = databox("Book", bookboxtitle, page_no_numeric, page_total_numeric, book_time_left, page_no_display, page_total_display, {
        hide_title = content_mode == CONTENT_MODE_HIGHLIGHT_PROGRESS,
        hide_time = content_mode == CONTENT_MODE_HIGHLIGHT_PROGRESS,
        total_time_text = book_total_time_text,
        today_time_text = book_today_time_text,
    })
    local chapterbox = content_mode ~= CONTENT_MODE_HIGHLIGHT_PROGRESS and databox("Chapter", chapter_title, chapter_done, chapter_total, chapter_time_left) or nil

    local bg_choice = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING)
    local show_cover = not (Device.screen_saver_mode and bg_choice == "book_cover")
    local cover_widget
    if show_cover and ui.bookinfo and ui.document then
        local cover_bb = ui.bookinfo:getCoverImage(ui.document)
        if cover_bb then
            local cover_width = cover_bb:getWidth()
            local cover_height = cover_bb:getHeight()
            local max_width = math.floor(widget_width * BOOK_RECEIPT_COVER_SCALE)
            local max_height = math.floor(Screen:getHeight() / 3 * BOOK_RECEIPT_COVER_SCALE)
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
    local highlight_widgets
    local highlight_length = 0
    if content_mode == CONTENT_MODE_HIGHLIGHT_PROGRESS then
        local highlight_item = getRandomHighlightAnnotation(ui)
        if highlight_item then
            local highlight_text = util.trim(highlight_item.text or "")
            if highlight_text ~= "" then
                local truncated_text, char_count, was_truncated = utf8TrimToLength(highlight_text, MAX_HIGHLIGHT_SIZE)
                highlight_length = char_count
                if was_truncated then
                    truncated_text = truncated_text .. "..."
                end

                local meta_parts = {}
                if highlight_item.chapter and highlight_item.chapter ~= "" then
                    table.insert(meta_parts, highlight_item.chapter)
                end
                local highlight_page = highlight_item.pageref or highlight_item.pageno
                if not highlight_page and highlight_item.page and type(highlight_item.page) == "string" and ui.document and ui.document.getPageFromXPointer then
                    local ok, page_from_xp = pcall(ui.document.getPageFromXPointer, ui.document, highlight_item.page)
                    if ok then
                        highlight_page = page_from_xp
                    end
                end
                if highlight_page then
                    local page_label
                    if type(highlight_page) == "number" then
                        page_label = string.format("%s %s", _("Page"), tostring(highlight_page))
                    else
                        page_label = highlight_page
                    end
                    table.insert(meta_parts, page_label)
                end
                if #meta_parts > 0 then
                    highlight_widgets = {
                        TextBoxWidget:new{
                            face = Font:getFace("cfont", db_font_size_big),
                            text = truncated_text,
                            width = widget_width,
                            fgcolor = db_font_color,
                            bold = true,
                            alignment = "center",
                        },
                        VerticalSpan:new{ width = db_padding_internal },
                        TextWidget:new{
                            text = string.format("(%s)", table.concat(meta_parts, ", ")),
                            face = Font:getFace("cfont", db_font_size_small),
                            bold = false,
                            fgcolor = db_font_color_lighter,
                            padding = 0,
                            align = "center",
                        },
                    }
                else
                    highlight_widgets = {
                        TextBoxWidget:new{
                            face = Font:getFace("cfont", db_font_size_big),
                            text = truncated_text,
                            width = widget_width,
                            fgcolor = db_font_color,
                            bold = true,
                            alignment = "center",
                        },
                    }
                end
            end
        end
        if not highlight_widgets then
            content_mode = CONTENT_MODE_BOOK_RECEIPT
        end
    end

    if content_mode == CONTENT_MODE_BOOK_RECEIPT then
        show_cover = not (Device.screen_saver_mode and bg_choice == "book_cover")
    else
        if bg_choice == "book_cover" or highlight_length > HIDE_COVER_FOR_LARGE_HIGHLIGHTS then
            show_cover = false
        end
    end

    if cover_widget and show_cover then
        table.insert(content_children, cover_widget)
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
    end
    if content_mode ~= CONTENT_MODE_HIGHLIGHT_PROGRESS and chapterbox then
        table.insert(content_children, chapterbox)
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
    end
    table.insert(content_children, bookbox)

    if content_mode == CONTENT_MODE_HIGHLIGHT_PROGRESS and highlight_widgets then
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
        util.arrayAppend(content_children, highlight_widgets)
    end
    if message_text then
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
        table.insert(content_children, VerticalGroup:new{
            TextBoxWidget:new{
                face = Font:getFace(db_font_face, db_font_size_mid),
                text = message_text,
                width = widget_width,
                fgcolor = db_font_color,
                bold = true,
                alignment = "center",
            },
            VerticalSpan:new{ width = db_padding_internal },
        })
    end
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
    covers_fullscreen = true,
}  

function quicklookbox:init()
    local receipt_widget = buildReceipt(self.ui, self.state)
    if receipt_widget then
        self[1] = receipt_widget
    else
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
    local ui = self
    UIManager:nextTick(function()
        if not ui then return end
        local widget = quicklookbox:new{
            ui = ui,
            document = ui.document,
            state = ui.view and ui.view.state,
        }
        UIManager:show(widget)
    end)
end

-- Screensaver integration

local Screensaver = require("ui/screensaver")

local orig_screensaver_show = Screensaver.show

Screensaver.show = function(self)
    if self.screensaver_type ~= "book_receipt" then
        return orig_screensaver_show(self)
    end

    local ui = self.ui or ReaderUI.instance
    if not hasActiveDocument(ui) then
        showFallbackScreensaver(self, orig_screensaver_show)
        return
    end

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

    local state = ui and ui.view and ui.view.state
    local receipt_widget = buildReceipt(ui, state)

    if receipt_widget then
        local background_color, background_widget = getReceiptBackground(ui)
        local widget_to_show = receipt_widget

        if background_widget then
            widget_to_show = OverlapGroup:new{
                dimen = Screen:getSize(),
                background_widget,
                receipt_widget,
            }
        end

        self.screensaver_widget = ScreenSaverWidget:new{
            widget = widget_to_show,
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
end

-- Add screensaver menu option

local orig_dofile = dofile

_G.dofile = function(filepath)
    local result = orig_dofile(filepath)

    if filepath and filepath:match("screensaver_menu%.lua$") then

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

            local function isBookReceiptEnabled()
                return G_reader_settings:readSetting("screensaver_type") == "book_receipt"
            end

            table.insert(wallpaper_submenu, 6,
                genMenuItem(_("Show book receipt on sleep screen"), "screensaver_type", "book_receipt")
            )

            local background_menu = {
                text = _("Background"),
                sub_item_table = {
                    genMenuItem(_("White fill"), BOOK_RECEIPT_BG_SETTING, "white"),
                    genMenuItem(_("Transparent"), BOOK_RECEIPT_BG_SETTING, "transparent"),
                    genMenuItem(_("Black fill"), BOOK_RECEIPT_BG_SETTING, "black"),
                    genMenuItem(_("Random image"), BOOK_RECEIPT_BG_SETTING, "random_image"),
                    genMenuItem(_("Book cover"), BOOK_RECEIPT_BG_SETTING, "book_cover"),
                    {
                        text = _("Background image placement"),
                        enabled_func = function()
                            local value = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING)
                            return value == "random_image" or value == "book_cover"
                        end,
                        sub_item_table = {
                            genMenuItem(_("Fit to screen"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "fit"),
                            genMenuItem(_("Stretch to screen"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "stretch"),
                            genMenuItem(_("Center without scaling"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "center"),
                        },
                    },
                },
            }

            local function isContentMode(value)
                local current = G_reader_settings:readSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING) or CONTENT_MODE_BOOK_RECEIPT
                return current == value
            end

            local content_menu = {
                text = _("Content"),
                sub_item_table = {
                    {
                        text = _("Book receipt (default)"),
                        checked_func = function() return isContentMode(CONTENT_MODE_BOOK_RECEIPT) end,
                        callback = function()
                            G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_BOOK_RECEIPT)
                        end,
                        radio = true,
                    },
                    {
                        text = _("Highlight + progress"),
                        checked_func = function() return isContentMode(CONTENT_MODE_HIGHLIGHT_PROGRESS) end,
                        callback = function()
                            G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_HIGHLIGHT_PROGRESS)
                        end,
                        radio = true,
                    },
                    {
                        text = _("Random"),
                        checked_func = function() return isContentMode(CONTENT_MODE_RANDOM) end,
                        callback = function()
                            G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_RANDOM)
                        end,
                        radio = true,
                    },
                },
            }

            table.insert(wallpaper_submenu, 7, {
                text = _("Book receipt settings"),
                enabled_func = isBookReceiptEnabled,
                sub_item_table = {
                    background_menu,
                    content_menu,
                },
            })
        end
    end

    return result
end
