local Device = require("device")

-- NOTE: KOReader defaults equivalent (ratio_h = 1/8 of screen height, i.e. screen_height / 8 ≈ 12.5%).
--       This applies to both top (DTAP_ZONE_MENU) and bottom (DTAP_ZONE_CONFIG) base zones.
--       To match default exactly: set TOP_MENU_TAP_HEIGHT_PX (or BOTTOM) to (your_screen_height_px / 8).
--       Convention here:
--         0  => disable that gesture zone entirely
--        -1  => keep original KOReader height (default ratios)
--        >0 => explicit pixel height
local TOP_MENU_TAP_HEIGHT_PX = 0
local TOP_MENU_SWIPE_HEIGHT_PX = -1
local BOTTOM_MENU_TAP_HEIGHT_PX = 0
local BOTTOM_MENU_SWIPE_HEIGHT_PX = -1

local Screen = Device.screen

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function getScreenHeight()
    if Screen and type(Screen.getHeight) == "function" then
        return Screen:getHeight()
    end
    if Screen and type(Screen.getSize) == "function" then
        local s = Screen:getSize()
        if s and s.h then
            return s.h
        end
    end
end

local function buildZones(height_px, defaults_fn, allow_default_on_zero, allow_default_on_neg1)
    local function normalizeDefaults()
        if type(defaults_fn) ~= "function" then return end
        local d, e = defaults_fn()
        -- normalize to ratio_* fields even if original keys are x/y/w/h
        local function norm(z, fallback_y, fallback_h, fallback_x, fallback_w)
            return {
                ratio_x = tonumber(z and (z.ratio_x or z.x)) or fallback_x or 0,
                ratio_y = tonumber(z and (z.ratio_y or z.y)) or fallback_y or 0,
                ratio_w = tonumber(z and (z.ratio_w or z.w)) or fallback_w or 1,
                ratio_h = tonumber(z and (z.ratio_h or z.h)) or fallback_h or 0,
            }
        end
        local top_y = tonumber(d and (d.ratio_y or d.y)) or 0
        d = norm(d, top_y, tonumber(d and (d.ratio_h or d.h)) or 0, d and (d.ratio_x or d.x), d and (d.ratio_w or d.w))
        e = norm(e, tonumber(e and (e.ratio_y or e.y)) or top_y, tonumber(e and (e.ratio_h or e.h)) or d.ratio_h, e and (e.ratio_x or e.x) or (1/4), e and (e.ratio_w or e.w) or (2/4))
        if d and d.ratio_h > 0 then
            return d, e
        end
    end

    if type(height_px) ~= "number" then
        return
    end
    if height_px == -1 and allow_default_on_neg1 then
        local d, e = normalizeDefaults()
        return d, e
    end
    if height_px <= 0 then
        if allow_default_on_zero then
            local d, e = normalizeDefaults()
            return d, e
        end
        return
    end

    local screen_h = getScreenHeight()
    if type(screen_h) ~= "number" or screen_h <= 0 then
        if (allow_default_on_zero or allow_default_on_neg1) and type(defaults_fn) == "function" then
            return defaults_fn()
        end
        return
    end

    local ratio_h = clamp01(height_px / screen_h)
    if ratio_h <= 0 then
        if (allow_default_on_zero or allow_default_on_neg1) and type(defaults_fn) == "function" then
            return defaults_fn()
        end
        return
    end

    local zone, zone_ext = defaults_fn()
    if not zone then
        return
    end
    -- Normalize numeric fields; preserve x/w if present, override h with ratio_h.
    local function norm(z, fallback_y, fallback_h, fallback_x, fallback_w)
        return {
            ratio_x = tonumber(z and (z.ratio_x or z.x)) or fallback_x or 0,
            ratio_y = tonumber(z and (z.ratio_y or z.y)) or fallback_y or 0,
            ratio_w = tonumber(z and (z.ratio_w or z.w)) or fallback_w or 1,
            ratio_h = fallback_h,
        }
    end

    local top_y = tonumber(zone.ratio_y) or 0
    zone = norm(zone, top_y, ratio_h, zone.ratio_x, zone.ratio_w)
    zone_ext = norm(zone_ext, zone_ext and zone_ext.ratio_y or top_y, ratio_h, zone_ext and zone_ext.ratio_x or (1/4), zone_ext and zone_ext.ratio_w or (2/4))

    return zone, zone_ext
end

local function sanitizeZone(z)
    if type(z) ~= "table" then return nil end
    if type(z.ratio_x) ~= "number" then return nil end
    if type(z.ratio_y) ~= "number" then return nil end
    if type(z.ratio_w) ~= "number" then return nil end
    if type(z.ratio_h) ~= "number" then return nil end
    return z
end

local function ensureValidZones(zones)
    local out = {}
    for _, z in ipairs(zones) do
        local sz = sanitizeZone(z.screen_zone)
        if sz then
            z.screen_zone = sz
            table.insert(out, z)
        end
    end
    return out
end

local function getTopTapZones()
    return buildZones(TOP_MENU_TAP_HEIGHT_PX, function()
        local d = G_defaults:readSetting("DTAP_ZONE_MENU")
        local e = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
        return d, e
    end, false, true) -- -1 => default, 0 => disable
end

local function getTopSwipeZones()
    return buildZones(TOP_MENU_SWIPE_HEIGHT_PX, function()
        local d = G_defaults:readSetting("DTAP_ZONE_MENU")
        local e = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
        return d, e
    end, false, true) -- -1 => default, 0 => disable
end

local function getBottomTapZones()
    return buildZones(BOTTOM_MENU_TAP_HEIGHT_PX, function()
        local d = G_defaults:readSetting("DTAP_ZONE_CONFIG")
        local e = G_defaults:readSetting("DTAP_ZONE_CONFIG_EXT")
        return d, e
    end, false, true) -- -1 => default, 0 => disable
end

local function getBottomSwipeZones()
    return buildZones(BOTTOM_MENU_SWIPE_HEIGHT_PX, function()
        local d = G_defaults:readSetting("DTAP_ZONE_CONFIG")
        local e = G_defaults:readSetting("DTAP_ZONE_CONFIG_EXT")
        return d, e
    end, false, true) -- -1 => default, 0 => disable
end

local ok_reader_menu, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
if ok_reader_menu and ReaderMenu then
    ReaderMenu.initGesListener = function(self)
        if not Device:isTouchDevice() then return end

        local tap_zone, tap_ext = getTopTapZones()
        local swipe_zone, swipe_ext = getTopSwipeZones()

        -- Nothing to register if both are disabled
        if not tap_zone and not swipe_zone then
            return
        end

        local zones = {}
        tap_zone = sanitizeZone(tap_zone)
        tap_ext = sanitizeZone(tap_ext or tap_zone)
        swipe_zone = sanitizeZone(swipe_zone)
        swipe_ext = sanitizeZone(swipe_ext or swipe_zone)

        if tap_zone then
            table.insert(zones, {
                id = "readermenu_tap",
                ges = "tap",
                screen_zone = tap_zone,
                overrides = {
                    "tap_forward",
                    "tap_backward",
                },
                handler = function(ges) return self:onTapShowMenu(ges) end,
            })
            table.insert(zones, {
                id = "readermenu_ext_tap",
                ges = "tap",
                screen_zone = tap_ext or tap_zone,
                overrides = {
                    "readermenu_tap",
                },
                handler = function(ges) return self:onTapShowMenu(ges) end,
            })
        end
        if swipe_zone then
            table.insert(zones, {
                id = "readermenu_swipe",
                ges = "swipe",
                screen_zone = swipe_zone,
                overrides = {
                    "rolling_swipe",
                    "paging_swipe",
                },
                handler = function(ges) return self:onSwipeShowMenu(ges) end,
            })
            table.insert(zones, {
                id = "readermenu_ext_swipe",
                ges = "swipe",
                screen_zone = swipe_ext or swipe_zone,
                overrides = {
                    "readermenu_swipe",
                },
                handler = function(ges) return self:onSwipeShowMenu(ges) end,
            })
            table.insert(zones, {
                id = "readermenu_pan",
                ges = "pan",
                screen_zone = swipe_zone,
                overrides = {
                    "rolling_pan",
                    "paging_pan",
                },
                handler = function(ges) return self:onSwipeShowMenu(ges) end,
            })
            table.insert(zones, {
                id = "readermenu_ext_pan",
                ges = "pan",
                screen_zone = swipe_ext or swipe_zone,
                overrides = {
                    "readermenu_pan",
                },
                handler = function(ges) return self:onSwipeShowMenu(ges) end,
            })
        end
        zones = ensureValidZones(zones)
        if #zones > 0 then
            self.ui:registerTouchZones(zones)
        end
    end

    ReaderMenu.onReaderReady = ReaderMenu.initGesListener
end

local ok_reader_config, ReaderConfig = pcall(require, "apps/reader/modules/readerconfig")
if ok_reader_config and ReaderConfig then
    ReaderConfig.initGesListener = function(self)
        if not Device:isTouchDevice() then return end

        local tap_zone, tap_ext = getBottomTapZones()
        local swipe_zone, swipe_ext = getBottomSwipeZones()

        if not tap_zone and not swipe_zone then
            return
        end

        local zones = {}
        tap_zone = sanitizeZone(tap_zone)
        tap_ext = sanitizeZone(tap_ext or tap_zone)
        swipe_zone = sanitizeZone(swipe_zone)
        swipe_ext = sanitizeZone(swipe_ext or swipe_zone)

        if tap_zone then
            table.insert(zones, {
                id = "readerconfigmenu_tap",
                ges = "tap",
                screen_zone = tap_zone,
                overrides = {
                    "tap_forward",
                    "tap_backward",
                },
                handler = function() return self:onTapShowConfigMenu() end,
            })
            table.insert(zones, {
                id = "readerconfigmenu_ext_tap",
                ges = "tap",
                screen_zone = tap_ext or tap_zone,
                overrides = {
                    "readerconfigmenu_tap",
                },
                handler = function() return self:onTapShowConfigMenu() end,
            })
        end
        if swipe_zone then
            table.insert(zones, {
                id = "readerconfigmenu_swipe",
                ges = "swipe",
                screen_zone = swipe_zone,
                overrides = {
                    "rolling_swipe",
                    "paging_swipe",
                },
                handler = function(ges) return self:onSwipeShowConfigMenu(ges) end,
            })
            table.insert(zones, {
                id = "readerconfigmenu_ext_swipe",
                ges = "swipe",
                screen_zone = swipe_ext or swipe_zone,
                overrides = {
                    "readerconfigmenu_swipe",
                },
                handler = function(ges) return self:onSwipeShowConfigMenu(ges) end,
            })
            table.insert(zones, {
                id = "readerconfigmenu_pan",
                ges = "pan",
                screen_zone = swipe_zone,
                overrides = {
                    "rolling_pan",
                    "paging_pan",
                },
                handler = function(ges) return self:onSwipeShowConfigMenu(ges) end,
            })
            table.insert(zones, {
                id = "readerconfigmenu_ext_pan",
                ges = "pan",
                screen_zone = swipe_ext or swipe_zone,
                overrides = {
                    "readerconfigmenu_pan",
                },
                handler = function(ges) return self:onSwipeShowConfigMenu(ges) end,
            })
        end
        if #zones > 0 then
            self.ui:registerTouchZones(zones)
        end
    end
end

local ok_filemanager_menu, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
if ok_filemanager_menu and FileManagerMenu then
    FileManagerMenu.initGesListener = function(self)
        if not Device:isTouchDevice() then return end

        local tap_zone, tap_ext = getTopTapZones()
        local swipe_zone, swipe_ext = getTopSwipeZones()

        if not tap_zone and not swipe_zone then
            return
        end

        local zones = {}
        tap_zone = sanitizeZone(tap_zone)
        tap_ext = sanitizeZone(tap_ext or tap_zone)
        swipe_zone = sanitizeZone(swipe_zone)
        swipe_ext = sanitizeZone(swipe_ext or swipe_zone)

        if tap_zone then
            table.insert(zones, {
                id = "filemanager_tap",
                ges = "tap",
                screen_zone = tap_zone,
                handler = function(ges) return self:onTapShowMenu(ges) end,
            })
            table.insert(zones, {
                id = "filemanager_ext_tap",
                ges = "tap",
                screen_zone = tap_ext or tap_zone,
                overrides = {
                    "filemanager_tap",
                },
                handler = function(ges) return self:onTapShowMenu(ges) end,
            })
        end
        if swipe_zone then
            table.insert(zones, {
                id = "filemanager_swipe",
                ges = "swipe",
                screen_zone = swipe_zone,
                overrides = {
                    "rolling_swipe",
                    "paging_swipe",
                },
                handler = function(ges) return self:onSwipeShowMenu(ges) end,
            })
            table.insert(zones, {
                id = "filemanager_ext_swipe",
                ges = "swipe",
                screen_zone = swipe_ext or swipe_zone,
                overrides = {
                    "filemanager_swipe",
                },
                handler = function(ges) return self:onSwipeShowMenu(ges) end,
            })
        end
        if #zones > 0 then
            self:registerTouchZones(zones)
        end
    end
end
