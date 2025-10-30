-- Sleep Overlay patch: blends a random overlay image onto the current sleep cover.
-- Place transparent PNG overlays in the KOReader "sleepoverlays" folder.

local Blitbuffer = require("ffi/blitbuffer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local RenderImage = require("ui/renderimage")
local Screensaver = require("ui/screensaver")
local util = require("util")
local math_floor = math.floor
local math_abs = math.abs

local joinPath = ffiUtil.joinPath
local overlay_dir = ffiUtil.realpath("sleepoverlays") or "sleepoverlays"

-- Overlay scaling mode: choose between "fit", "fill", "center", "stretch".
--   fit    : scale overlay to fit inside the cover while keeping aspect ratio.
--   fill   : scale overlay to cover the entire screen (may crop) with aspect ratio preserved.
--   center : keep original overlay size and center it; larger images get cropped.
--   stretch: stretch overlay to screen size without preserving aspect ratio.
local overlay_resize_mode = "stretch"
local overlay_candidates
local random_seeded

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

local function ensureBaseImage(self)
    if self.image then
        return self.image
    end
    if not self.image_file then
        return nil
    end

    local base_bb = RenderImage:renderImageFile(self.image_file, false, nil, nil)
    if base_bb then
        self.image = base_bb
        self.image_file = nil
    end
    return base_bb
end

local function composeOverlay(self)
    if not self:modeIsImage() then
        return
    end
    if self._sleep_overlay_applied then
        return
    end

    local base_bb = ensureBaseImage(self)
    if not base_bb then
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

    local base_w, base_h = base_bb:getWidth(), base_bb:getHeight()
    local overlay_w, overlay_h = overlay_bb:getWidth(), overlay_bb:getHeight()

    local resize_mode = type(overlay_resize_mode) == "string" and overlay_resize_mode:lower() or "fit"
    if resize_mode ~= "center" then
        if resize_mode ~= "stretch" then
            local scale
            if resize_mode == "fill" then
                scale = math.max(base_w / overlay_w, base_h / overlay_h)
            else -- default to fit
                scale = math.min(base_w / overlay_w, base_h / overlay_h)
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
            if overlay_w ~= base_w or overlay_h ~= base_h then
                local stretched = RenderImage:scaleBlitBuffer(overlay_bb, base_w, base_h)
                if stretched then
                    if overlay_bb.free then overlay_bb:free() end
                    overlay_bb = stretched
                    overlay_w, overlay_h = overlay_bb:getWidth(), overlay_bb:getHeight()
                end
            end
        end
    end

    local width = math.min(base_w, overlay_w)
    local height = math.min(base_h, overlay_h)
    if width <= 0 or height <= 0 then
        if overlay_bb.free then overlay_bb:free() end
        return
    end

    local dest_x, dest_y = 0, 0
    local src_x, src_y = 0, 0

    if overlay_w < base_w then
        dest_x = math_floor((base_w - overlay_w) / 2)
        width = overlay_w
    elseif overlay_w > base_w then
        src_x = math_floor((overlay_w - base_w) / 2)
        width = base_w
    end

    if overlay_h < base_h then
        dest_y = math_floor((base_h - overlay_h) / 2)
        height = overlay_h
    elseif overlay_h > base_h then
        src_y = math_floor((overlay_h - base_h) / 2)
        height = base_h
    end

    local overlay_type = overlay_bb.getType and overlay_bb:getType()
    local base_type = base_bb.getType and base_bb:getType()

    if overlay_type == Blitbuffer.TYPE_BBRGB32 or overlay_type == Blitbuffer.TYPE_BB8A then
        if base_type ~= overlay_type then
            local old_base = base_bb
            local converted_base = Blitbuffer.new(base_w, base_h, overlay_type)
            converted_base:blitFrom(old_base, 0, 0, 0, 0, base_w, base_h)
            base_bb = converted_base
            self.image = base_bb
            self.image_file = nil
            base_type = overlay_type
            if old_base ~= base_bb and old_base.free then
                old_base:free()
            end
        end
    elseif base_type and overlay_type and overlay_type ~= base_type then
        local converted_overlay = Blitbuffer.new(overlay_w, overlay_h, base_type)
        converted_overlay:blitFrom(overlay_bb, 0, 0, 0, 0, overlay_w, overlay_h)
        if overlay_bb.free then overlay_bb:free() end
        overlay_bb = converted_overlay
        overlay_type = base_type
    end

    base_w, base_h = base_bb:getWidth(), base_bb:getHeight()
    overlay_w, overlay_h = overlay_bb:getWidth(), overlay_bb:getHeight()
    width = math.min(width, base_w)
    height = math.min(height, base_h)
    if width <= 0 or height <= 0 then
        if overlay_bb.free then overlay_bb:free() end
        return
    end

    local ok, err = pcall(function()
        if overlay_type == Blitbuffer.TYPE_BBRGB32 or overlay_type == Blitbuffer.TYPE_BB8A then
            base_bb:alphablitFrom(overlay_bb, dest_x, dest_y, src_x, src_y, width, height)
        else
            base_bb:blitFrom(overlay_bb, dest_x, dest_y, src_x, src_y, width, height)
        end
    end)
    if not ok then
        logger.err("SleepOverlay: blit failed", err)
    end

    if overlay_bb.free then overlay_bb:free() end
    self._sleep_overlay_applied = true
    logger.dbg("SleepOverlay: applied overlay", overlay_path)
end

local orig_show = Screensaver.show
function Screensaver:show(...)
    local ok, err = pcall(composeOverlay, self)
    if not ok then
        logger.err("SleepOverlay: compose failed", err)
    end
    return orig_show(self, ...)
end

local orig_cleanup = Screensaver.cleanup
function Screensaver:cleanup()
    self._sleep_overlay_applied = nil
    return orig_cleanup(self)
end
