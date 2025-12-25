local userpatch = require("userpatch")
local _ = require("gettext")

local function arrayContains(t, value)
    for _, v in ipairs(t) do
        if v == value then
            return true
        end
    end
    return false
end

local function insertAfter(t, value, after)
    if arrayContains(t, value) then
        return
    end
    local pos
    for i, v in ipairs(t) do
        if v == after then
            pos = i + 1
            break
        end
    end
    if pos then
        table.insert(t, pos, value)
    else
        table.insert(t, value)
    end
end

local function gestureHasActions(instance, ges_id)
    if not instance or type(instance.gestures) ~= "table" then
        return false
    end
    local actions = instance.gestures[ges_id]
    if type(actions) ~= "table" then
        return false
    end
    local count = 0
    for k in pairs(actions) do
        if k ~= "settings" then
            count = count + 1
        end
    end
    return count > 0
end

userpatch.registerPatchPluginFunc("gestures", function(plugin)
    local Gestures = plugin

    local section_items = userpatch.getUpValue(Gestures.addToMainMenu, "section_items")
    if type(section_items) == "table" and type(section_items.one_finger_swipe) == "table" then
        insertAfter(section_items.one_finger_swipe, "one_finger_swipe_top_edge_down", "one_finger_swipe_top_edge_left")
        insertAfter(section_items.one_finger_swipe, "one_finger_swipe_bottom_edge_up", "one_finger_swipe_bottom_edge_left")
    end

    local gestures_list = userpatch.getUpValue(Gestures.initGesture, "gestures_list")
    if type(gestures_list) == "table" then
        gestures_list.one_finger_swipe_top_edge_down = _("Top edge down")
        gestures_list.one_finger_swipe_bottom_edge_up = _("Bottom edge up")
    end

    local orig_setupGesture = Gestures.setupGesture
    Gestures.setupGesture = function(self, ges)
        if ges == "one_finger_swipe_top_edge_down" or ges == "one_finger_swipe_bottom_edge_up" then
            local dswipe_zone_top_edge = G_defaults:readSetting("DSWIPE_ZONE_TOP_EDGE")
            local zone_top_edge = {
                ratio_x = dswipe_zone_top_edge.x,
                ratio_y = dswipe_zone_top_edge.y,
                ratio_w = dswipe_zone_top_edge.w,
                ratio_h = dswipe_zone_top_edge.h,
            }

            local dswipe_zone_bottom_edge = G_defaults:readSetting("DSWIPE_ZONE_BOTTOM_EDGE")
            local zone_bottom_edge = {
                ratio_x = dswipe_zone_bottom_edge.x,
                ratio_y = dswipe_zone_bottom_edge.y,
                ratio_w = dswipe_zone_bottom_edge.w,
                ratio_h = dswipe_zone_bottom_edge.h,
            }

            local zone
            local direction
            if ges == "one_finger_swipe_top_edge_down" then
                zone = zone_top_edge
                direction = { south = true }
            else
                zone = zone_bottom_edge
                direction = { north = true }
            end

            local overrides
            local overrides_pan
            local overrides_pan_release
            local overrides_swipe_pan
            local overrides_swipe_pan_release

            if self.is_docless then
                overrides = {
                    "filemanager_ext_swipe",
                    "filemanager_swipe",
                }
            else
                overrides = {
                    "swipe_link",
                    "readerconfigmenu_ext_swipe",
                    "readerconfigmenu_swipe",
                    "readerconfigmenu_ext_pan",
                    "readerconfigmenu_pan",
                    "readermenu_ext_swipe",
                    "readermenu_swipe",
                    "readermenu_ext_pan",
                    "readermenu_pan",
                    "paging_swipe",
                    "rolling_swipe",
                }
            end

            self:registerGesture(ges, "swipe", zone, overrides, direction)

            local pan_gesture = ges .. "_pan"
            local pan_release_gesture = ges .. "_pan_release"
            self.ui:registerTouchZones({
                {
                    id = pan_gesture,
                    ges = "pan",
                    screen_zone = zone,
                    overrides = overrides,
                    handler = function(ev)
                        if direction and not direction[ev.direction] then return end
                        if gestureHasActions(self, ges) then
                            return true
                        end
                    end,
                },
                {
                    id = pan_release_gesture,
                    ges = "pan_release",
                    screen_zone = zone,
                    overrides = overrides,
                    handler = function(ev)
                        if direction and not direction[ev.direction] then return end
                        if gestureHasActions(self, ges) then
                            return true
                        end
                    end,
                },
            })

            return
        end

        return orig_setupGesture(self, ges)
    end

    local PluginLoader = require("pluginloader")
    local instance = PluginLoader:getPluginInstance("gestures")
    if instance and type(instance.setupGesture) == "function" then
        instance:setupGesture("one_finger_swipe_top_edge_down")
        instance:setupGesture("one_finger_swipe_bottom_edge_up")
    end
end)
