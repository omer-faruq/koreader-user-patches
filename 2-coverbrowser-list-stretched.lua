local ImageWidget = require("ui/widget/imagewidget")
local PluginLoader = require("pluginloader")
local Size = require("ui/size")

-- Aspect ratio (width / height) for the uniform cover slot.
-- 2/3 matches the most common portrait book-cover ratio.
-- Increase toward 1.0 for a squarer look, decrease for taller covers.
local COVER_RATIO = 2 / 3

-- IMPORTANT: do NOT add stretch_limit_percentage here.
-- When that option triggers scale-to-fit, the rendered _bb becomes smaller
-- than the reported getSize() slot, causing negative blitFrom offsets that
-- read out-of-bounds memory → Segmentation Fault.
-- Always stretching to the exact slot guarantees _bb == slot dimensions,
-- so offsets are always (0,0) and blitFrom is always in bounds.

-- ---------------------------------------------------------------------------
-- Shared slot dimensions (set once per ListMenuItem:init, used by both the
-- book-cover and the folder-cover StretchingImageWidget instances).
-- ---------------------------------------------------------------------------
local slot_h  -- available image height in pixels
local slot_w  -- portrait-ratio width  in pixels
local border_size = Size.border.thin
local underline_h = 1 -- matches ListMenuItem:init() → self.underline_h = 1

-- The StretchingImageWidget class is built after we have the base ImageWidget
-- reference and is reused for both book covers and folder covers.
local StretchingImageWidget  -- assigned inside patch_coverbrowser

-- Forward declarations for the two patch functions defined below.
local patch_coverbrowser
local patch_simpleui_folder_covers

-- ---------------------------------------------------------------------------
-- Hook PluginLoader to catch both coverbrowser and simpleui.
-- ---------------------------------------------------------------------------
local orig_PluginLoader_createPluginInstance = PluginLoader.createPluginInstance
PluginLoader.createPluginInstance = function(self, plugin, attr)
    local ok, plugin_or_err = orig_PluginLoader_createPluginInstance(self, plugin, attr)
    if ok then
        if plugin.name == "coverbrowser" then
            patch_coverbrowser(plugin)
        elseif plugin.name == "simpleui" then
            -- simpleui calls FC.install() synchronously inside its :init(), so
            -- _setListFolderCover is already installed on ListMenuItem by now.
            patch_simpleui_folder_covers(plugin)
        end
    end
    return ok, plugin_or_err
end

-- ---------------------------------------------------------------------------
-- Patch 1 – book covers in ListMenuItem:update  (coverbrowser plugin)
-- ---------------------------------------------------------------------------
patch_coverbrowser = function(plugin)
    local ListMenu = require("listmenu")

    -- Find ListMenuItem in ListMenu._updateItemsBuildUI's upvalues
    local ListMenuItem
    local n = 1
    while true do
        local name, value = debug.getupvalue(ListMenu._updateItemsBuildUI, n)
        if not name then break end
        if name == "ListMenuItem" then ListMenuItem = value; break end
        n = n + 1
    end
    if not ListMenuItem then return end

    -- Find ImageWidget in ListMenuItem.update's upvalues
    local ImageWidgetLocal
    local setupvalue_n
    n = 1
    while true do
        local name, value = debug.getupvalue(ListMenuItem.update, n)
        if not name then break end
        if name == "ImageWidget" then
            ImageWidgetLocal = value
            setupvalue_n = n
            break
        end
        n = n + 1
    end
    if not ImageWidgetLocal then return end

    -- Capture slot dimensions inside a patched :init() so slot_h/slot_w are
    -- always set before update() builds the widget tree.
    local orig_ListMenuItem_init = ListMenuItem.init
    ListMenuItem.init = function(self)
        if self.height then
            local dimen_h = self.height - 2 * underline_h
            slot_h = dimen_h - 2 * border_size
            slot_w = math.floor(slot_h * COVER_RATIO)
        end
        orig_ListMenuItem_init(self)
    end

    -- Build the shared subclass now that we have a base ImageWidget reference.
    -- getSize() returns {w=self.width, h=self.height} when those are set, so
    -- the FrameContainer always receives slot_w+2b × slot_h+2b — identical
    -- for every item.  No stretch_limit_percentage: see note at the top.
    StretchingImageWidget = ImageWidgetLocal:extend{}
    StretchingImageWidget.init = function(self)
        if not slot_w or not slot_h then return end
        self.scale_factor     = nil   -- discard the pre-computed fit factor
        self.width            = slot_w      -- target: portrait slot width
        self.height           = slot_h      -- target: portrait slot height
        -- IMPORTANT: do NOT allow _render() to free the source cover_bb.
        -- With scale_factor=nil, _render() calls scaleBlitBuffer(..., free_orig_bb=_bb_disposable).
        -- If image_disposable were true (the default), BookInfoManager's cover_bb would be
        -- freed after the first render.  For folder covers, entry_data.cover_bb is a direct
        -- reference to that same bb stored in _lmcSet cache — subsequent navigations would
        -- then read from freed memory, causing visual corruption.
        -- Setting image_disposable=false keeps the bb alive; it is freed by the FFI finalizer
        -- when the bookinfo table (and therefore cover_bb) is garbage-collected normally.
        self.image_disposable = false
    end

    -- Replace the module-local ImageWidget for book covers
    debug.setupvalue(ListMenuItem.update, setupvalue_n, StretchingImageWidget)
end

-- ---------------------------------------------------------------------------
-- Patch 2 – folder covers in ListMenuItem:_setListFolderCover  (simpleui)
-- ---------------------------------------------------------------------------
-- Root cause of the navigation corruption:
--   _setListFolderCover creates ImageWidget{image = bookinfo.cover_bb} with
--   the default image_disposable=true.  During _render(), scaleBlitBuffer
--   frees that cover_bb when scale_factor ~= 1, or ImageWidget:free() frees
--   it when scale_factor == 1 (because _bb == cover_bb and _bb_disposable=true).
--   The _lmcSet cache stores entry_data.cover_bb as a direct reference to the
--   same blitbuffer — after the first render it becomes a dangling pointer.
--   Navigating back to the page then renders from freed memory → corruption.
--
-- Fix: wrap _setListFolderCover so it always receives a fresh copy of
--   cover_bb.  The copy is owned by the ImageWidget and freed normally;
--   the cached entry_data.cover_bb is never touched.
-- This approach requires no upvalue-name lookups and is therefore robust
-- regardless of debug-info availability or upvalue-sharing between closures.
patch_simpleui_folder_covers = function(plugin)
    local ok_lm, ListMenu = pcall(require, "listmenu")
    if not ok_lm or not ListMenu then return end

    local ListMenuItem
    local n = 1
    while true do
        local name, value = debug.getupvalue(ListMenu._updateItemsBuildUI, n)
        if not name then break end
        if name == "ListMenuItem" then ListMenuItem = value; break end
        n = n + 1
    end
    if not ListMenuItem or not ListMenuItem._setListFolderCover then return end

    local orig_sfc = ListMenuItem._setListFolderCover

    -- Apply the same portrait-2:3 stretching to folder covers as Patch 1 does
    -- for book covers: replace the ImageWidget upvalue with StretchingImageWidget.
    -- _setListFolderCover wraps the image in a CenterContainer, so a portrait
    -- frame is naturally centred inside the existing square slot – no layout
    -- changes needed.  Because _setListFolderCover and the simpleui update
    -- wrapper share the same ImageWidget upvalue cell (both are closures over
    -- the module-level local in sui_foldercovers.lua), this also updates the
    -- static .cover.* file-loading path in update; that path already copies
    -- the bb before storing it, so the shared-cell change is harmless there.
    if StretchingImageWidget then
        local n = 1
        while true do
            local name = debug.getupvalue(orig_sfc, n)
            if not name then break end
            if name == "ImageWidget" then
                debug.setupvalue(orig_sfc, n, StretchingImageWidget)
                break
            end
            n = n + 1
        end
    end

    function ListMenuItem:_setListFolderCover(bookinfo)
        if bookinfo and bookinfo.cover_bb then
            -- Pass a copy so the cached cover_bb is never freed by ImageWidget.
            orig_sfc(self, {
                cover_bb      = bookinfo.cover_bb:copy(),
                cover_w       = bookinfo.cover_w,
                cover_h       = bookinfo.cover_h,
                has_cover     = bookinfo.has_cover,
                cover_fetched = bookinfo.cover_fetched,
            })
        else
            orig_sfc(self, bookinfo)
        end
    end
end
