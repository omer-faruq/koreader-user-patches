-- Stops Autoturn when you have not touched the device for a while, or when the
-- battery drops below a threshold (useful when you fall asleep reading). Once
-- Autoturn stops it releases PluginShare.pause_auto_suspend, so AutoSuspend /
-- AutoShutdown take over as configured.
--
-- Settings: reader menu > Navigation tab (where Autoturn is), at the bottom of
-- the list > "Autoturn auto-stop":
--   * Enable auto-stop          (autoturn_autostop_enabled, off by default)
--   * Stop after inactivity     (autoturn_autostop_minutes, minutes; 0 = off)
--   * Stop below battery level  (autoturn_autostop_battery, percent; 0 = off)
-- Inactivity counts from the last real input; autoturn page turns don't count.
-- Conditions are checked on every autoturn tick. The battery check is skipped
-- while charging. On stop a "Continue / Stop" box is shown: Continue restarts
-- Autoturn (and, for the battery case, stops asking until the book is reopened);
-- Stop or tapping outside leaves it off. Stopping lasts for this session only:
-- the Autoturn setting itself stays on, so it starts again with the next book.

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local userpatch = require("userpatch")
local T = require("ffi/util").template

local S_ENABLED = "autoturn_autostop_enabled"
local S_MINUTES = "autoturn_autostop_minutes"
local S_BATTERY = "autoturn_autostop_battery"

local function stopReason(self)
    if not G_reader_settings:isTrue(S_ENABLED) then return end

    local minutes = G_reader_settings:readSetting(S_MINUTES, 0)
    if minutes > 0 then
        local now = UIManager:getElapsedTimeSinceBoot()
        -- The instance created before this patch ran has no input timestamp yet.
        self._autostop_last_input = self._autostop_last_input or now
        if now - self._autostop_last_input >= time.s(minutes * 60) then
            return T("Autoturn stopped: no input for %1 min.", minutes), "inactivity"
        end
    end

    local battery = G_reader_settings:readSetting(S_BATTERY, 0)
    if battery > 0 and not self._autostop_battery_ack and Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        if not powerd:isCharging() and powerd:getCapacity() < battery then
            return T("Autoturn stopped: battery below %1 %.", battery), "battery"
        end
    end
end

local function spinSetting(touchmenu, key, title, info, unit, max, step, hold_step)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = title,
        info_text = info,
        unit = unit,
        value = G_reader_settings:readSetting(key, 0),
        value_min = 0,
        value_max = max,
        value_step = step,
        value_hold_step = hold_step,
        default_value = 0,
        callback = function(spin)
            G_reader_settings:saveSetting(key, spin.value)
            touchmenu:updateItems()
        end,
    })
end

userpatch.registerPatchPluginFunc("autoturn", function(AutoTurn)
    if AutoTurn._autostop_patched then return end
    AutoTurn._autostop_patched = true

    local orig_onInputEvent = AutoTurn.onInputEvent
    AutoTurn.onInputEvent = function(self, ...)
        self._autostop_last_input = UIManager:getElapsedTimeSinceBoot()
        return orig_onInputEvent(self, ...)
    end

    -- Starting autoturn (menu, resume) is user activity too.
    local orig_start = AutoTurn._start
    AutoTurn._start = function(self)
        self._autostop_last_input = UIManager:getElapsedTimeSinceBoot()
        return orig_start(self)
    end

    -- Every autoturn tick goes through _schedule.
    local orig_schedule = AutoTurn._schedule
    AutoTurn._schedule = function(self)
        if self:_enabled() then
            local reason, kind = stopReason(self)
            if reason then
                self:_unschedule() -- also clears pause_auto_suspend
                local on_resume = self.onResume
                self.onResume = nil -- don't restart on wakeup
                UIManager:show(ConfirmBox:new{
                    text = reason,
                    ok_text = "Continue",
                    cancel_text = "Stop",
                    ok_callback = function()
                        if not self.task then return end -- document closed meanwhile
                        -- Low battery doesn't recover; don't ask again this session.
                        if kind == "battery" then self._autostop_battery_ack = true end
                        self.onResume = on_resume
                        self:_start() -- resets the inactivity timer
                    end,
                })
                return
            end
        end
        return orig_schedule(self)
    end

    local orig_addToMainMenu = AutoTurn.addToMainMenu
    AutoTurn.addToMainMenu = function(self, menu_items)
        orig_addToMainMenu(self, menu_items)
        menu_items.autoturn_autostop = {
            sorting_hint = "navi",
            text = "Autoturn auto-stop",
            sub_item_table = {
                {
                    text = "Enable auto-stop",
                    checked_func = function() return G_reader_settings:isTrue(S_ENABLED) end,
                    callback = function() G_reader_settings:flipNilOrFalse(S_ENABLED) end,
                },
                {
                    text_func = function()
                        local m = G_reader_settings:readSetting(S_MINUTES, 0)
                        return m > 0 and T("Stop after inactivity: %1 min", m) or "Stop after inactivity: off"
                    end,
                    enabled_func = function() return G_reader_settings:isTrue(S_ENABLED) end,
                    keep_menu_open = true,
                    callback = function(touchmenu)
                        spinSetting(touchmenu, S_MINUTES, "Stop after inactivity",
                            "Minutes since your last touch or key press.\n0 = off.", "min", 24 * 60, 1, 15)
                    end,
                },
                {
                    text_func = function()
                        local b = G_reader_settings:readSetting(S_BATTERY, 0)
                        return b > 0 and T("Stop below battery: %1 %", b) or "Stop below battery: off"
                    end,
                    enabled_func = function() return G_reader_settings:isTrue(S_ENABLED) end,
                    keep_menu_open = true,
                    callback = function(touchmenu)
                        spinSetting(touchmenu, S_BATTERY, "Stop below battery level",
                            "Ignored while charging.\n0 = off.", "%", 100, 1, 10)
                    end,
                },
            },
        }
    end
end)
