--[[
Screensaver Always Full Refresh Patch
=====================================
Forces a full e-ink refresh (white flash + refreshFull) right before the
screensaver/sleep screen appears, no matter which screensaver type is active,
and adds a "Full refresh count" item to the bottom of the sleep screen
settings to control how many times this happens.

Why
---
Stock KOReader only flashes/refreshes the screen first for the "cover" and
"random_image" screensaver types (see Screensaver:modeIsImage() in
frontend/ui/screensaver.lua). Other types — "message", "disable" with an
overlay, or custom screensavers added by plugins/patches (e.g. book receipt,
SimpleUI home screen, sleep overlay) — draw directly on top of whatever was
on screen, which can leave ghosting on eInk displays.

This patch wraps Screensaver:setup() — which always runs immediately before
Screensaver:show(), for every screensaver type, with no bypass branches —
so the full-refresh flash always runs first on eInk devices, regardless of
screensaver type (including custom show() overrides installed by other
patches/plugins that don't delegate back to the previous show for their own
type). The user picks how many refresh passes to do via a new
"Full refresh count" menu item:
  • 0       — patch does nothing (refresh skipped entirely)
  • 1       — one refresh pass (default)
  • 2 or up — that many consecutive refresh passes (more aggressive
              ghosting removal at the cost of extra time/flashing)

Installation
------------
Copy this file into: koreader/patches/2-screensaver-always-full-refresh.lua
--]]

local Device = require("device")
local Screen = Device.screen
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

if not Device:hasEinkScreen() then
    return  -- nothing to do on non-eInk devices
end

local SK_REFRESH_COUNT = "screensaver_full_refresh_count"
local DEFAULT_COUNT    = 1

-- ── 1. Inject "Full refresh count" item at the bottom of the sleep screen menu ──
local function _injectIntoMenuTable(tbl)
    if type(tbl) ~= "table" then
        logger.warn("ScreensaverFullRefresh patch: unexpected screensaver_menu structure")
        return
    end

    table.insert(tbl, {
        text_func = function()
            local count = G_reader_settings:readSetting(SK_REFRESH_COUNT) or DEFAULT_COUNT
            return T(_("Full refresh count before sleep screen: %1"), count)
        end,
        help_text = _("How many times to fully flash/refresh the e-ink screen right before the sleep screen appears. Set to 0 to disable; higher values remove ghosting more aggressively at the cost of extra time and flashing."),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager  = require("ui/uimanager")
            UIManager:show(SpinWidget:new{
                title_text      = _("Full refresh count"),
                info_text       = _("Number of full e-ink refreshes to perform right before the sleep screen appears. 0 disables this."),
                value           = G_reader_settings:readSetting(SK_REFRESH_COUNT) or DEFAULT_COUNT,
                value_min       = 0,
                value_max       = 5,
                value_step      = 1,
                value_hold_step = 1,
                default_value   = DEFAULT_COUNT,
                ok_text         = _("Set count"),
                callback        = function(w)
                    G_reader_settings:saveSetting(SK_REFRESH_COUNT, w.value)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            })
        end,
    })
end

-- ── 2. Patch Screensaver.show() to always refresh first ────────────────────
local _patched = false

-- NOTE: we hook Screensaver:setup(), NOT Screensaver:show().
-- Some screensaver-type patches (e.g. SimpleUI's "screensaver_homescreen")
-- install their own Screensaver.show that, for their own type, renders
-- everything itself and returns WITHOUT calling through to the previous
-- (wrapped) show — so a wrapper placed on `show` can end up never being
-- invoked for that type. `setup()` has no such bypass: it always runs,
-- always delegates to the original unconditionally, and always runs
-- immediately before `show()` with no intervening screen changes — so
-- doing the refresh here is equivalent to doing it at the top of show(),
-- but it can't be skipped by a type-specific show() override.
local function patchSetup(Screensaver)
    if _patched then return true end
    if type(Screensaver) ~= "table" then return false end

    local orig_setup = Screensaver.setup
    local orig_setup_type = type(orig_setup)
    if orig_setup_type ~= "function" then
        local mt = orig_setup_type == "table" and getmetatable(orig_setup)
        if not (mt and mt.__call) then
            logger.warn("ScreensaverFullRefresh patch: setup is not callable (type="
                        .. orig_setup_type .. ")")
            return false
        end
    end

    _patched = true
    Screensaver.setup = function(self, event, event_message)
        local count = G_reader_settings:readSetting(SK_REFRESH_COUNT) or DEFAULT_COUNT
        if count > 0 then
            local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
            for _i = 1, count do
                Screen:clear()
                Screen:refreshFull(0, 0, screen_w, screen_h)
            end
        end
        return orig_setup(self, event, event_message)
    end

    logger.info("ScreensaverFullRefresh patch: Screensaver.setup patched")
    return true
end

local ok, Screensaver = pcall(require, "ui/screensaver")
if ok and type(Screensaver) == "table" and Screensaver.setup ~= nil then
    patchSetup(Screensaver)
else
    -- Not loaded yet at this point — wrap require to catch the first load.
    local orig_require = _G.require
    _G.require = function(modname, ...)
        local result = orig_require(modname, ...)
        if modname == "ui/screensaver" and not _patched
           and type(result) == "table" and result.setup ~= nil then
            patchSetup(result)
            _G.require = orig_require
        end
        return result
    end
end

-- ── 3. Wrap dofile() for screensaver_menu injection ────────────────────────
local _orig_dofile = _G.dofile
_G.dofile = function(path, ...)
    local result = _orig_dofile(path, ...)
    if type(path) == "string" and path:find("screensaver_menu%.lua$") then
        _injectIntoMenuTable(result)
    end
    return result
end
