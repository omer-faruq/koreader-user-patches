-- Sleep Overlay patch: choose between full-screen overlays and playful sticker layouts for the sleep screen.
-- Overlay mode covers the entire display with a random PNG from the "sleepoverlays" folder.
-- Sticker mode uses PNG files from "sleepoverlay_stickers" either in the four corners or scattered randomly.
-- Quick sticker tweaks:
--   use_stickers: turn sticker mode on/off
--   sticker_mode: "corners" or "random"
--   sticker_max_fraction: largest sticker size relative to screen
--   sticker_min_distance_fraction: spacing between stickers
--   sticker_random_min / sticker_random_max: how many stickers to drop in random mode

local Blitbuffer = require("ffi/blitbuffer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local RenderImage = require("ui/renderimage")
local Screensaver = require("ui/screensaver")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local util = require("util")
local math_floor = math.floor
local math_abs = math.abs
local math_min = math.min
local math_max = math.max
local math_sqrt = math.sqrt

local table_remove = table.remove

local joinPath = ffiUtil.joinPath

local use_stickers = false
local sticker_mode = "random" -- options: "corners", "random"
local sticker_max_fraction = 1 / 3
local sticker_min_distance_fraction = 1 / 5
local sticker_random_min = 1
local sticker_random_max = 6
local overlay_dir = ffiUtil.realpath("sleepoverlays") or "sleepoverlays"
local sticker_dir = ffiUtil.realpath("sleepoverlay_stickers") or "sleepoverlay_stickers"

-- Overlay scaling mode: choose between "fit", "fill", "center", "stretch".
--   fit    : scale overlay to fit inside the cover while keeping aspect ratio.
--   fill   : scale overlay to cover the entire screen (may crop) with aspect ratio preserved.
--   center : keep original overlay size and center it; larger images get cropped.
--   stretch: stretch overlay to screen size without preserving aspect ratio.
local overlay_resize_mode = "stretch"
local sticker_candidates

-- Apply overlay only when the screensaver is showing an image (cover/random/custom).
-- Set to false to allow overlay on widgets such as reading progress or book status.
local overlay_only_on_images = false

-- When the resulting image carries an alpha channel, flatten it onto a solid background
-- so that ImageWidget can display it without turning transparent regions black.
local flatten_alpha_background = true
local flatten_alpha_color = Blitbuffer.COLOR_WHITE
local overlay_candidates
local random_seeded

local function refreshStickerList()
    sticker_candidates = {}
    local attr = lfs.attributes(sticker_dir, "mode")
    if attr ~= "directory" then
        logger.dbg("SleepOverlay: sticker directory not found", sticker_dir)
        sticker_candidates = nil
        return
    end

    for entry in lfs.dir(sticker_dir) do
        if entry ~= "." and entry ~= ".." then
            local full = joinPath(sticker_dir, entry)
            local mode = lfs.attributes(full, "mode")
            if mode == "file" then
                local suffix = util.getFileNameSuffix(entry)
                if suffix and suffix:lower() == "png" then
                    table.insert(sticker_candidates, full)
                end
            end
        end
    end

    if #sticker_candidates == 0 then
        sticker_candidates = nil
        logger.dbg("SleepOverlay: no sticker PNGs in", sticker_dir)
    end
end

local OverlayPainter = Widget:extend{
    name = "SleepOverlayPainter",
    overlay_bb = nil,
    overlay_disposable = true,
    dest_x = 0,
    dest_y = 0,
    src_x = 0,
    src_y = 0,
    width = 0,
    height = 0,
    screen_w = 0,
    screen_h = 0,
}

function OverlayPainter:getSize()
    return Geom:new{ w = self.screen_w, h = self.screen_h }
end

function OverlayPainter:paintTo(bb, x, y)
    if not self.overlay_bb then
        return
    end
    local draw_x = x + self.dest_x
    local draw_y = y + self.dest_y
    local ok, err = pcall(function()
        bb:alphablitFrom(self.overlay_bb, draw_x, draw_y, self.src_x, self.src_y, self.width, self.height)
    end)
    if not ok then
        logger.err("SleepOverlay: overlay paint failed", err)
    end
end

function OverlayPainter:free()
    if self.overlay_disposable and self.overlay_bb and self.overlay_bb.free then
        self.overlay_bb:free()
    end
    self.overlay_bb = nil
end

local function seedRandom()
    if not random_seeded then
        random_seeded = true
        math.randomseed(os.time())
    end
end

local function refreshOverlayList()
    overlay_candidates = {}
    local attr = lfs.attributes(overlay_dir, "mode")
    if attr ~= "directory" then
        logger.dbg("SleepOverlay: overlay directory not found", overlay_dir)
        return
    end

    for entry in lfs.dir(overlay_dir) do
        if entry ~= "." and entry ~= ".." then
            local full = joinPath(overlay_dir, entry)
            local mode = lfs.attributes(full, "mode")
            if mode == "file" then
                local suffix = util.getFileNameSuffix(entry)
                if suffix and suffix:lower() == "png" then
                    table.insert(overlay_candidates, full)
                end
            end
        end
    end

    if #overlay_candidates == 0 then
        overlay_candidates = nil
        logger.dbg("SleepOverlay: no PNG overlays in", overlay_dir)
    end
end

local function pickOverlayPath()
    if not overlay_candidates then
        refreshOverlayList()
    end
    if not overlay_candidates then
        return nil
    end
    seedRandom()
    local idx = math.random(#overlay_candidates)
    return overlay_candidates[idx]
end

local function prepareStickerBuffer(path, max_w, max_h)
    local sticker_bb = RenderImage:renderImageFile(path, false, nil, nil)
    if not sticker_bb then
        logger.dbg("SleepOverlay: failed to render sticker", path)
        return nil
    end

    local sticker_w, sticker_h = sticker_bb:getWidth(), sticker_bb:getHeight()
    if sticker_w <= 0 or sticker_h <= 0 then
        if sticker_bb.free then sticker_bb:free() end
        logger.dbg("SleepOverlay: sticker has invalid dimensions", path)
        return nil
    end

    local limit_w = math_max(1, max_w)
    local limit_h = math_max(1, max_h)
    local scale = 1

    if sticker_w > limit_w or sticker_h > limit_h then
        scale = math_min(limit_w / sticker_w, limit_h / sticker_h)
    elseif sticker_w < limit_w and sticker_h < limit_h then
        scale = math_max(limit_w / sticker_w, limit_h / sticker_h)
    end

    if scale > 0 and math_abs(scale - 1) > 0.0001 then
        local target_w = math_max(1, math_floor(sticker_w * scale + 0.5))
        local target_h = math_max(1, math_floor(sticker_h * scale + 0.5))
        local scaled = RenderImage:scaleBlitBuffer(sticker_bb, target_w, target_h)
        if scaled then
            if sticker_bb.free then sticker_bb:free() end
            sticker_bb = scaled
        end
    end

    local sticker_type = sticker_bb.getType and sticker_bb:getType()
    if sticker_type ~= Blitbuffer.TYPE_BBRGB32 and sticker_type ~= Blitbuffer.TYPE_BB8A then
        sticker_w, sticker_h = sticker_bb:getWidth(), sticker_bb:getHeight()
        local converted = Blitbuffer.new(sticker_w, sticker_h, Blitbuffer.TYPE_BBRGB32)
        converted:blitFrom(sticker_bb, 0, 0, 0, 0, sticker_w, sticker_h)
        if sticker_bb.free then sticker_bb:free() end
        sticker_bb = converted
    end

    sticker_w, sticker_h = sticker_bb:getWidth(), sticker_bb:getHeight()

    if Screen.night_mode then
        sticker_bb:invertRect(0, 0, sticker_w, sticker_h)
    end

    return sticker_bb, sticker_w, sticker_h
end

local function composeStencilFromCorners(screen_w, screen_h, max_sticker_w, max_sticker_h)
    if not sticker_candidates or #sticker_candidates == 0 then
        return nil
    end

    local available = {}
    for i = 1, #sticker_candidates do
        available[i] = sticker_candidates[i]
    end

    local corners = {
        { name = "top_left",    dest = function(w, h) return 0, 0 end },
        { name = "top_right",   dest = function(w, h) return screen_w - w, 0 end },
        { name = "bottom_left", dest = function(w, h) return 0, screen_h - h end },
        { name = "bottom_right",dest = function(w, h) return screen_w - w, screen_h - h end },
    }

    for i = #corners, 2, -1 do
        local swap_idx = math.random(i)
        corners[i], corners[swap_idx] = corners[swap_idx], corners[i]
    end

    local placed_any = false
    local painters = {}

    for _, corner in ipairs(corners) do
        if #available == 0 then
            break
        end

        if math.random() < 0.2 then
            goto continue_corner
        end

        local pick_idx = math.random(#available)
        local sticker_path = available[pick_idx]
        table_remove(available, pick_idx)

        local sticker_bb, sticker_w, sticker_h = prepareStickerBuffer(sticker_path, max_sticker_w, max_sticker_h)
        if sticker_bb then
            local dest_x, dest_y = corner.dest(sticker_w, sticker_h)
            dest_x = math_max(0, math_floor(dest_x))
            dest_y = math_max(0, math_floor(dest_y))

            local painter = OverlayPainter:new{
                overlay_bb = sticker_bb,
                overlay_disposable = true,
                dest_x = dest_x,
                dest_y = dest_y,
                src_x = 0,
                src_y = 0,
                width = sticker_w,
                height = sticker_h,
                screen_w = screen_w,
                screen_h = screen_h,
            }
            table.insert(painters, painter)
            placed_any = true
        end

        ::continue_corner::
    end

    if not placed_any then
        return nil
    end

    local children = { allow_mirroring = false }
    for _, painter in ipairs(painters) do
        table.insert(children, painter)
    end

    return OverlapGroup:new(children)
end

local function composeStencilRandom(screen_w, screen_h, max_sticker_w, max_sticker_h)
    if not sticker_candidates or #sticker_candidates == 0 then
        return nil
    end

    local available = {}
    for i = 1, #sticker_candidates do
        available[i] = sticker_candidates[i]
    end

    local min_distance = math_max(0, sticker_min_distance_fraction) * math_min(screen_w, screen_h)

    local count_min = math_max(0, sticker_random_min)
    local count_max = math_max(count_min, sticker_random_max)
    count_max = math_min(count_max, #available)
    if count_max == 0 then
        return nil
    end

    if count_min > count_max then
        count_min = count_max
    end

    local target_count = count_min
    if count_max > count_min then
        target_count = math.random(count_min, count_max)
    end

    local placed_any = false
    local painters = {}
    local used_positions = {}

    for _ = 1, target_count do
        if #available == 0 then
            break
        end

        local pick_idx = math.random(#available)
        local sticker_path = available[pick_idx]
        table_remove(available, pick_idx)

        local sticker_bb, sticker_w, sticker_h = prepareStickerBuffer(sticker_path, max_sticker_w, max_sticker_h)
        if sticker_bb then
            local attempts = 20
            local placed = false
            local max_x = math_max(0, screen_w - sticker_w)
            local max_y = math_max(0, screen_h - sticker_h)
            while attempts > 0 do
                attempts = attempts - 1
                local dest_x = max_x > 0 and math_floor(math.random() * max_x) or 0
                local dest_y = max_y > 0 and math_floor(math.random() * max_y) or 0

                local valid = true
                for _, pos in ipairs(used_positions) do
                    local dx = dest_x - pos.x
                    local dy = dest_y - pos.y
                    if math_sqrt(dx * dx + dy * dy) < min_distance then
                        valid = false
                        break
                    end
                end

                if valid then
                    local painter = OverlayPainter:new{
                        overlay_bb = sticker_bb,
                        overlay_disposable = true,
                        dest_x = dest_x,
                        dest_y = dest_y,
                        src_x = 0,
                        src_y = 0,
                        width = sticker_w,
                        height = sticker_h,
                        screen_w = screen_w,
                        screen_h = screen_h,
                    }
                    table.insert(painters, painter)
                    table.insert(used_positions, { x = dest_x, y = dest_y })
                    placed = true
                    placed_any = true
                    break
                end
            end

            if not placed then
                if sticker_bb.free then sticker_bb:free() end
            end
        end
    end

    if not placed_any then
        return nil
    end

    local children = { allow_mirroring = false }
    for _, painter in ipairs(painters) do
        table.insert(children, painter)
    end

    return OverlapGroup:new(children)
end

local function composeOverlay(self)
    if self._sleep_overlay_applied then
        return
    end

    if overlay_only_on_images and not self:modeIsImage() then
        return
    end

    if use_stickers then
        if not sticker_candidates then
            refreshStickerList()
        end
        local overlay_widget
        if sticker_candidates then
            seedRandom()
            local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
            local max_size = math_max(0.01, sticker_max_fraction)
            local max_sticker_w = screen_w * max_size
            local max_sticker_h = screen_h * max_size

            if sticker_mode == "random" then
                overlay_widget = composeStencilRandom(screen_w, screen_h, max_sticker_w, max_sticker_h)
            else
                overlay_widget = composeStencilFromCorners(screen_w, screen_h, max_sticker_w, max_sticker_h)
            end
        end
        if overlay_widget then
            self._sleep_overlay_widget = overlay_widget
            self._sleep_overlay_applied = true
        end
        return
    end

    local overlay_path = pickOverlayPath()
    if not overlay_path then
        return
    end

    local overlay_bb = RenderImage:renderImageFile(overlay_path, false, nil, nil)
    if not overlay_bb then
        logger.dbg("SleepOverlay: failed to render overlay", overlay_path)
        return
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local overlay_w, overlay_h = overlay_bb:getWidth(), overlay_bb:getHeight()

    local resize_mode = type(overlay_resize_mode) == "string" and overlay_resize_mode:lower() or "fit"
    if resize_mode ~= "center" then
        if resize_mode ~= "stretch" then
            local scale
            if resize_mode == "fill" then
                scale = math.max(screen_w / overlay_w, screen_h / overlay_h)
            else -- default to fit
                scale = math.min(screen_w / overlay_w, screen_h / overlay_h)
            end
            if scale and scale > 0 and math.abs(scale - 1) > 0.0001 then
                local target_w = math.max(1, math.floor(overlay_w * scale + 0.5))
                local target_h = math.max(1, math.floor(overlay_h * scale + 0.5))
                local scaled = RenderImage:scaleBlitBuffer(overlay_bb, target_w, target_h)
                if scaled then
                    if overlay_bb.free then overlay_bb:free() end
                    overlay_bb = scaled
                    overlay_w, overlay_h = overlay_bb:getWidth(), overlay_bb:getHeight()
                end
            end
        else
            if overlay_w ~= screen_w or overlay_h ~= screen_h then
                local stretched = RenderImage:scaleBlitBuffer(overlay_bb, screen_w, screen_h)
                if stretched then
                    if overlay_bb.free then overlay_bb:free() end
                    overlay_bb = stretched
                    overlay_w, overlay_h = overlay_bb:getWidth(), overlay_bb:getHeight()
                end
            end
        end
    end

    local width = math.min(screen_w, overlay_w)
    local height = math.min(screen_h, overlay_h)
    if width <= 0 or height <= 0 then
        if overlay_bb.free then overlay_bb:free() end
        return
    end

    local dest_x, dest_y = 0, 0
    local src_x, src_y = 0, 0

    if overlay_w < screen_w then
        dest_x = math_floor((screen_w - overlay_w) / 2)
        width = overlay_w
    elseif overlay_w > screen_w then
        src_x = math_floor((overlay_w - screen_w) / 2)
        width = screen_w
    end

    if overlay_h < screen_h then
        dest_y = math_floor((screen_h - overlay_h) / 2)
        height = overlay_h
    elseif overlay_h > screen_h then
        src_y = math_floor((overlay_h - screen_h) / 2)
        height = screen_h
    end

    local overlay_type = overlay_bb.getType and overlay_bb:getType()
    if overlay_type ~= Blitbuffer.TYPE_BBRGB32 and overlay_type ~= Blitbuffer.TYPE_BB8A then
        local converted_overlay = Blitbuffer.new(overlay_w, overlay_h, Blitbuffer.TYPE_BBRGB32)
        converted_overlay:blitFrom(overlay_bb, 0, 0, 0, 0, overlay_w, overlay_h)
        if overlay_bb.free then overlay_bb:free() end
        overlay_bb = converted_overlay
        overlay_type = Blitbuffer.TYPE_BBRGB32
        overlay_w, overlay_h = overlay_bb:getWidth(), overlay_bb:getHeight()
    end

    if Screen.night_mode then
        overlay_bb:invertRect(0, 0, overlay_w, overlay_h)
    end

    local overlay_widget = OverlayPainter:new{
        overlay_bb = overlay_bb,
        overlay_disposable = true,
        dest_x = dest_x,
        dest_y = dest_y,
        src_x = src_x,
        src_y = src_y,
        width = width,
        height = height,
        screen_w = screen_w,
        screen_h = screen_h,
    }

    self._sleep_overlay_widget = overlay_widget
    self._sleep_overlay_applied = true
end

local function attachOverlayToScreensaverWidget(sswidget, base_widget)
    if not sswidget or sswidget._sleep_overlay_wrapped then
        return
    end
    local widget_to_wrap = base_widget or sswidget.widget
    if not widget_to_wrap then
        return
    end
    if not Screensaver._sleep_overlay_widget then
        local ok, err = pcall(composeOverlay, Screensaver)
        if not ok then
            logger.err("SleepOverlay: compose during widget attach failed", err)
            return
        end
    end
    local overlay_widget = Screensaver._sleep_overlay_widget
    if not overlay_widget then
        return
    end
    sswidget.widget = OverlapGroup:new{
        allow_mirroring = false,
        widget_to_wrap,
        overlay_widget,
    }
    sswidget._sleep_overlay_wrapped = true
    if sswidget.update then
        sswidget:update()
    end
    UIManager:setDirty(sswidget, function()
        return "full", sswidget.main_frame and sswidget.main_frame.dimen or sswidget.region
    end)
    Screensaver._sleep_overlay_widget = nil
end

local orig_show = Screensaver.show
function Screensaver:show(...)
    local ok, err = pcall(composeOverlay, self)
    if not ok then
        logger.err("SleepOverlay: compose failed", err)
    end
    local result = orig_show(self, ...)
    attachOverlayToScreensaverWidget(self.screensaver_widget)
    return result
end

local orig_cleanup = Screensaver.cleanup
function Screensaver:cleanup()
    if self._sleep_overlay_widget and self._sleep_overlay_widget.free then
        self._sleep_overlay_widget:free()
    end
    self._sleep_overlay_applied = nil
    self._sleep_overlay_widget = nil
    if self.screensaver_widget then
        self.screensaver_widget._sleep_overlay_wrapped = nil
    end
    return orig_cleanup(self)
end

local orig_sswidget_init = ScreenSaverWidget.init
function ScreenSaverWidget:init(...)
    local existing_widget = self.widget
    orig_sswidget_init(self, ...)
    attachOverlayToScreensaverWidget(self, existing_widget)
end
