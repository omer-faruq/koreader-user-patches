-- To use "Book mode screensavers", you must create the "book_mode_screensavers" folder and put your images inside it.
-- To use "Book list screensavers", you must create the "book_list_screensavers" folder and put your images inside it.

local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local _ = require("gettext")

local Screensaver = require("ui/screensaver")
local ImageWidget = require("ui/widget/imagewidget")

local PATCHED_FLAG = "__dual_state_screensaver_patched"

local SCREEN_SAVER_TYPE_DUAL_STATE = "dual_state"

local BOOK_LIST_FOLDER = ffiUtil.realpath("book_list_screensavers") or "book_list_screensavers"
local BOOK_MODE_FOLDER = ffiUtil.realpath("book_mode_screensavers") or "book_mode_screensavers"

local BOOK_LIST_TOKEN = "__dual_state_book_list_screensavers__"
local BOOK_MODE_TOKEN = "__dual_state_book_mode_screensavers__"

local SETTINGS_KEY_BOOK_LIST = "dual_state_book_list_choice"
local SETTINGS_KEY_BOOK_MODE = "dual_state_book_mode_choice"

local SETTINGS_KEY_BOOK_LIST_PLACEMENT = "dual_state_book_list_placement"
local SETTINGS_KEY_BOOK_MODE_PLACEMENT = "dual_state_book_mode_placement"

local function safeText(item)
    if item.text then
        return item.text
    end
    if item.text_func then
        local ok, res = pcall(item.text_func)
        if ok and res then
            return res
        end
    end
    return nil
end

local function extractRadioValue(item)
    if type(item) ~= "table" or not item.radio or type(item.callback) ~= "function" then
        return nil
    end

    local setting
    local value

    local i = 1
    while true do
        local name, up = debug.getupvalue(item.callback, i)
        if not name then
            break
        end
        if name == "setting" then
            setting = up
        elseif name == "value" then
            value = up
        end
        if setting and value then
            break
        end
        i = i + 1
    end

    if setting == "screensaver_type" and type(value) == "string" then
        return value
    end

    return nil
end

local function folderExists(path)
    return path and lfs.attributes(path, "mode") == "directory"
end

local function ensureDefaultChoices()
    if G_reader_settings:hasNot(SETTINGS_KEY_BOOK_LIST) then
        if folderExists(BOOK_LIST_FOLDER) then
            G_reader_settings:saveSetting(SETTINGS_KEY_BOOK_LIST, BOOK_LIST_TOKEN)
        else
            G_reader_settings:saveSetting(SETTINGS_KEY_BOOK_LIST, "random_image")
        end
    end

    if G_reader_settings:hasNot(SETTINGS_KEY_BOOK_MODE) then
        if folderExists(BOOK_MODE_FOLDER) then
            G_reader_settings:saveSetting(SETTINGS_KEY_BOOK_MODE, BOOK_MODE_TOKEN)
        else
            G_reader_settings:saveSetting(SETTINGS_KEY_BOOK_MODE, "cover")
        end
    end

    if G_reader_settings:hasNot(SETTINGS_KEY_BOOK_LIST_PLACEMENT) then
        G_reader_settings:saveSetting(SETTINGS_KEY_BOOK_LIST_PLACEMENT, "stretch")
    end

    if G_reader_settings:hasNot(SETTINGS_KEY_BOOK_MODE_PLACEMENT) then
        G_reader_settings:saveSetting(SETTINGS_KEY_BOOK_MODE_PLACEMENT, "stretch")
    end
end

local function genPlacementMenu(mode)
    ensureDefaultChoices()

    local selection_key = mode == "book_mode" and SETTINGS_KEY_BOOK_MODE or SETTINGS_KEY_BOOK_LIST
    local placement_key = mode == "book_mode" and SETTINGS_KEY_BOOK_MODE_PLACEMENT or SETTINGS_KEY_BOOK_LIST_PLACEMENT
    local token = mode == "book_mode" and BOOK_MODE_TOKEN or BOOK_LIST_TOKEN

    local enabled_for_mode = function()
        return G_reader_settings:readSetting(selection_key) == token
    end

    local genPlacementItem = function(text, value, separator)
        return {
            text = text,
            enabled_func = enabled_for_mode,
            checked_func = function()
                return G_reader_settings:readSetting(placement_key) == value
            end,
            callback = function()
                G_reader_settings:saveSetting(placement_key, value)
            end,
            radio = true,
            separator = separator,
        }
    end

    return {
        genPlacementItem("center", "center"),
        genPlacementItem("fit", "fit"),
        genPlacementItem("stretch", "stretch"),
    }
end

local function buildAvailableWallpaperTypes(wallpaper_submenu)
    local out = {}
    local seen = {}

    for _, item in ipairs(wallpaper_submenu) do
        local val = extractRadioValue(item)
        if val and val ~= SCREEN_SAVER_TYPE_DUAL_STATE and not seen[val] then
            seen[val] = true
            table.insert(out, {
                value = val,
                label = safeText(item) or val,
            })
        end
    end

    return out
end

local function genChoiceItem(text, settings_key, choice_value, separator)
    return {
        text = text,
        enabled_func = function()
            if choice_value == BOOK_LIST_TOKEN then
                return folderExists(BOOK_LIST_FOLDER)
            end
            if choice_value == BOOK_MODE_TOKEN then
                return folderExists(BOOK_MODE_FOLDER)
            end
            return true
        end,
        checked_func = function()
            return G_reader_settings:readSetting(settings_key) == choice_value
        end,
        callback = function()
            G_reader_settings:saveSetting(settings_key, choice_value)
        end,
        radio = true,
        separator = separator,
    }
end

local function genModeMenu(mode)
    ensureDefaultChoices()

    local orig_menu = dofile("frontend/ui/elements/screensaver_menu.lua")
    local wallpaper_submenu = orig_menu and orig_menu[1] and orig_menu[1].sub_item_table
    if type(wallpaper_submenu) ~= "table" then
        return {}
    end

    local available = buildAvailableWallpaperTypes(wallpaper_submenu)

    local menu = {}
    if mode == "book_list" then
        table.insert(menu, genChoiceItem("Book list screensavers", SETTINGS_KEY_BOOK_LIST, BOOK_LIST_TOKEN, false))
        table.insert(menu, {
            text = "Book list screensavers settings",
            enabled_func = function()
                return G_reader_settings:readSetting(SETTINGS_KEY_BOOK_LIST) == BOOK_LIST_TOKEN
            end,
            sub_item_table_func = function()
                return genPlacementMenu("book_list")
            end,
            separator = true,
        })
        for _, entry in ipairs(available) do
            table.insert(menu, genChoiceItem(entry.label, SETTINGS_KEY_BOOK_LIST, entry.value))
        end
    else
        table.insert(menu, genChoiceItem("Book mode screensavers", SETTINGS_KEY_BOOK_MODE, BOOK_MODE_TOKEN, false))
        table.insert(menu, {
            text = "Book mode screensavers settings",
            enabled_func = function()
                return G_reader_settings:readSetting(SETTINGS_KEY_BOOK_MODE) == BOOK_MODE_TOKEN
            end,
            sub_item_table_func = function()
                return genPlacementMenu("book_mode")
            end,
            separator = true,
        })
        for _, entry in ipairs(available) do
            table.insert(menu, genChoiceItem(entry.label, SETTINGS_KEY_BOOK_MODE, entry.value))
        end
    end

    return menu
end

local function patchScreensaverMenu(result)
    if type(result) ~= "table" or result[PATCHED_FLAG] then
        return result
    end

    local wallpaper = result[1]
    if type(wallpaper) ~= "table" or type(wallpaper.sub_item_table) ~= "table" then
        return result
    end

    local wallpaper_submenu = wallpaper.sub_item_table

    local insert_at
    for idx, item in ipairs(wallpaper_submenu) do
        if extractRadioValue(item) == "disable" then
            insert_at = idx
            break
        end
    end
    if not insert_at then
        insert_at = #wallpaper_submenu + 1
    end

    local function genDualStateMenuItem(text, value, separator)
        return {
            text = text,
            checked_func = function()
                return G_reader_settings:readSetting("screensaver_type") == value
            end,
            callback = function()
                G_reader_settings:saveSetting("screensaver_type", value)
            end,
            radio = true,
            separator = separator,
        }
    end

    table.insert(wallpaper_submenu, insert_at, genDualStateMenuItem(_("Dual-state screensaver mode"), SCREEN_SAVER_TYPE_DUAL_STATE))
    table.insert(wallpaper_submenu, insert_at + 1, {
        text = "Dual state settings",
        enabled_func = function()
            return G_reader_settings:readSetting("screensaver_type") == SCREEN_SAVER_TYPE_DUAL_STATE
        end,
        sub_item_table_func = function()
            return {
                {
                    text = "Book list mode",
                    sub_item_table_func = function()
                        return genModeMenu("book_list")
                    end,
                },
                {
                    text = "Book mode",
                    sub_item_table_func = function()
                        return genModeMenu("book_mode")
                    end,
                },
            }
        end,
        separator = true,
    })

    result[PATCHED_FLAG] = true
    return result
end

local orig_dofile = _G.dofile
_G.dofile = function(filepath)
    local res = orig_dofile(filepath)

    if type(filepath) == "string" and filepath:match("screensaver_menu%.lua$") then
        res = patchScreensaverMenu(res)
    end

    return res
end

local function getContextMode()
    local ui = require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
    if ui and ui.document then
        return "book_mode"
    end
    return "book_list"
end

local function backupSetting(key)
    if G_reader_settings:has(key) then
        return true, G_reader_settings:readSetting(key)
    end
    return false, nil
end

local function restoreSetting(key, existed, value)
    if existed then
        G_reader_settings:saveSetting(key, value)
    else
        G_reader_settings:delSetting(key)
    end
end

local function getPlacementForContext(context)
    if context == "book_mode" then
        return G_reader_settings:readSetting(SETTINGS_KEY_BOOK_MODE_PLACEMENT) or "stretch"
    end
    return G_reader_settings:readSetting(SETTINGS_KEY_BOOK_LIST_PLACEMENT) or "stretch"
end

local orig_setup = Screensaver.setup
Screensaver.setup = function(self, event, event_message)
    if self._dual_state_dispatching then
        return orig_setup(self, event, event_message)
    end

    local prefix = event and (event .. "_") or ""

    local current_type = G_reader_settings:readSetting(prefix .. "screensaver_type")
        or G_reader_settings:readSetting("screensaver_type")

    if current_type ~= SCREEN_SAVER_TYPE_DUAL_STATE then
        return orig_setup(self, event, event_message)
    end

    ensureDefaultChoices()

    local context = getContextMode()
    local selection_key = context == "book_mode" and SETTINGS_KEY_BOOK_MODE or SETTINGS_KEY_BOOK_LIST
    local selection = G_reader_settings:readSetting(selection_key)

    self._dual_state_effective_dir = nil
    self._dual_state_placement = nil

    local effective_type = selection
    local effective_dir

    if selection == BOOK_LIST_TOKEN then
        effective_type = "random_image"
        effective_dir = BOOK_LIST_FOLDER
    elseif selection == BOOK_MODE_TOKEN then
        effective_type = "random_image"
        effective_dir = BOOK_MODE_FOLDER
    end

    if effective_dir then
        self._dual_state_effective_dir = effective_dir
        self._dual_state_placement = getPlacementForContext(context)
    end

    if type(effective_type) ~= "string" then
        effective_type = "random_image"
    end

    local type_key = prefix .. "screensaver_type"
    local dir_key = prefix .. "screensaver_dir"

    local type_existed, type_old = backupSetting(type_key)
    local dir_existed, dir_old = backupSetting(dir_key)

    G_reader_settings:saveSetting(type_key, effective_type)
    if effective_dir then
        G_reader_settings:saveSetting(dir_key, effective_dir)
    end

    local top_setup = Screensaver.setup
    self._dual_state_dispatching = true
    local ok, err = pcall(top_setup, self, event, event_message)
    self._dual_state_dispatching = nil

    restoreSetting(type_key, type_existed, type_old)
    restoreSetting(dir_key, dir_existed, dir_old)

    if not ok then
        error(err)
    end

    return true
end

local function backupAndOverride(key, override_value)
    local existed, old = backupSetting(key)
    if override_value == nil then
        G_reader_settings:delSetting(key)
    else
        G_reader_settings:saveSetting(key, override_value)
    end
    return existed, old
end

local orig_show = Screensaver.show
Screensaver.show = function(self, ...)
    if self._dual_state_effective_dir and self.screensaver_type == "random_image" then
        local placement = self._dual_state_placement
        local stretch_existed, stretch_old
        local limit_existed, limit_old
        local rotate_existed, rotate_old
        local orig_new

        rotate_existed, rotate_old = backupAndOverride("screensaver_rotate_auto_for_best_fit", false)

        if placement == "fit" then
            stretch_existed, stretch_old = backupAndOverride("screensaver_stretch_images", false)
        elseif placement == "stretch" then
            stretch_existed, stretch_old = backupAndOverride("screensaver_stretch_images", true)
            limit_existed, limit_old = backupAndOverride("screensaver_stretch_limit_percentage", nil)
        elseif placement == "center" then
            stretch_existed, stretch_old = backupAndOverride("screensaver_stretch_images", false)
            orig_new = ImageWidget.new
            ImageWidget.new = function(class, settings)
                if type(settings) == "table" then
                    if settings.file and self.image_file and settings.file == self.image_file then
                        settings.scale_factor = 1
                        settings.stretch_limit_percentage = nil
                    end
                end
                return orig_new(class, settings)
            end
        end

        local ok, res = pcall(orig_show, self, ...)

        if orig_new then
            ImageWidget.new = orig_new
        end
        if rotate_existed ~= nil then
            restoreSetting("screensaver_rotate_auto_for_best_fit", rotate_existed, rotate_old)
        end
        if stretch_existed ~= nil then
            restoreSetting("screensaver_stretch_images", stretch_existed, stretch_old)
        end
        if limit_existed ~= nil then
            restoreSetting("screensaver_stretch_limit_percentage", limit_existed, limit_old)
        end

        if not ok then
            error(res)
        end
        return res
    end

    return orig_show(self, ...)
end

local orig_cleanup = Screensaver.cleanup
Screensaver.cleanup = function(self, ...)
    self._dual_state_effective_dir = nil
    self._dual_state_placement = nil
    return orig_cleanup(self, ...)
end
