local DocumentRegistry = require("document/documentregistry")
local Screensaver = require("ui/screensaver")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")

local RANDOM_BOOK_COVER_MODE = "random_book_cover"
local RANDOM_BOOK_COVER_COVER_MODE_KEY = "random_book_cover_cover_mode"
local RANDOM_BOOK_COVER_COVER_MODE_FIT = "fit"
local RANDOM_BOOK_COVER_COVER_MODE_STRETCH = "stretch"
local RANDOM_BOOK_COVER_COVER_MODE_CENTER = "center"
local RANDOM_BOOK_COVER_MIN_SCAN_FILES = 2048

local random_seeded = false
local function ensureRandomSeeded()
    if random_seeded then
        return
    end
    local entropy = tonumber(tostring({}):match("0x(%x+)") or "0", 16) or 0
    math.randomseed(os.time() + entropy)
    random_seeded = true
end

local function ensureRandomBookCoverDefaults()
    if G_reader_settings:hasNot(RANDOM_BOOK_COVER_COVER_MODE_KEY) then
        G_reader_settings:saveSetting(RANDOM_BOOK_COVER_COVER_MODE_KEY, RANDOM_BOOK_COVER_COVER_MODE_FIT)
    end
end

local function joinPath(dir, name)
    if dir:sub(-1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
end

local function collectDocumentCandidatesSkippingDotDirs(root, max_files, out)
    if not root then
        return
    end

    local resolved_root = ffiUtil.realpath(root) or root
    local function scan(current)
        local ok, iter, dir_obj = pcall(lfs.dir, current)
        if not ok then
            return
        end
        for name in iter, dir_obj do
            if #out >= max_files then
                return
            end
            local fullpath = current .. "/" .. name
            local attr = lfs.attributes(fullpath) or {}
            if attr.mode == "directory" then
                if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                    scan(fullpath)
                end
            elseif attr.mode == "file" or attr.mode == "link" then
                if DocumentRegistry:hasProvider(fullpath) then
                    out[#out + 1] = fullpath
                end
            end
        end
    end

    scan(resolved_root)
end

local function backupAndOverrideSetting(key, new_value)
    local settings = G_reader_settings
    local existed = settings:has(key)
    local old = settings:readSetting(key)
    settings:saveSetting(key, new_value)
    return existed, old
end

local function restoreSetting(key, existed, old)
    local settings = G_reader_settings
    if existed then
        settings:saveSetting(key, old)
    else
        settings:delSetting(key)
    end
end

local function backupSetting(key)
    local settings = G_reader_settings
    if settings:has(key) then
        return true, settings:readSetting(key)
    end
    return false, nil
end

local function restoreMaybeDeletedSetting(key, existed, old)
    local settings = G_reader_settings
    if existed then
        settings:saveSetting(key, old)
    else
        settings:delSetting(key)
    end
end

local orig_show = Screensaver.show
function Screensaver:show(...)
    if self._random_book_cover_enabled and (self.screensaver_type == "cover" or self.screensaver_type == "random_image") then
        local mode = self._random_book_cover_cover_mode or RANDOM_BOOK_COVER_COVER_MODE_FIT

        local stretch_existed, stretch_old = backupSetting("screensaver_stretch_images")
        local limit_existed, limit_old = backupSetting("screensaver_stretch_limit_percentage")

        local orig_new

        if mode == RANDOM_BOOK_COVER_COVER_MODE_FIT then
            G_reader_settings:makeFalse("screensaver_stretch_images")
        elseif mode == RANDOM_BOOK_COVER_COVER_MODE_STRETCH then
            G_reader_settings:makeTrue("screensaver_stretch_images")
            G_reader_settings:delSetting("screensaver_stretch_limit_percentage")
        elseif mode == RANDOM_BOOK_COVER_COVER_MODE_CENTER then
            G_reader_settings:makeFalse("screensaver_stretch_images")
            orig_new = require("ui/widget/imagewidget").new
            require("ui/widget/imagewidget").new = function(class, settings)
                if type(settings) == "table" then
                    if settings.file and self.image_file and settings.file == self.image_file then
                        settings.scale_factor = 1
                        settings.stretch_limit_percentage = nil
                    elseif settings.image and self.image and settings.image == self.image then
                        settings.scale_factor = 1
                        settings.stretch_limit_percentage = nil
                    end
                end
                return orig_new(class, settings)
            end
        end

        local ok, res = pcall(orig_show, self, ...)

        if orig_new then
            require("ui/widget/imagewidget").new = orig_new
        end
        restoreMaybeDeletedSetting("screensaver_stretch_images", stretch_existed, stretch_old)
        restoreMaybeDeletedSetting("screensaver_stretch_limit_percentage", limit_existed, limit_old)

        if not ok then
            error(res)
        end
        return res
    end

    return orig_show(self, ...)
end

local orig_cleanup = Screensaver.cleanup
function Screensaver:cleanup(...)
    self._random_book_cover_enabled = nil
    self._random_book_cover_cover_mode = nil
    return orig_cleanup(self, ...)
end

local function getEffectiveScreensaverType(prefix)
    local settings = G_reader_settings
    local prefixed_key = prefix and prefix ~= "" and (prefix .. "screensaver_type") or nil
    if prefixed_key and settings:has(prefixed_key) then
        return settings:readSetting(prefixed_key)
    end
    return settings:readSetting("screensaver_type")
end

local function getUI()
    return require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
end

local function getFileManagerFolder(ui)
    local path

    if ui and ui.file_chooser and type(ui.file_chooser.path) == "string" and ui.file_chooser.path ~= "" then
        path = ui.file_chooser.path
    end

    if (type(path) ~= "string" or path == "") and G_reader_settings then
        path = G_reader_settings:readSetting("lastdir")
    end

    if (type(path) ~= "string" or path == "") and G_reader_settings then
        local lastfile = G_reader_settings:readSetting("lastfile")
        if type(lastfile) == "string" and lastfile ~= "" then
            path = lastfile:match("(.*)/")
        end
    end

    if type(path) ~= "string" or path == "" then
        path = filemanagerutil.getDefaultDir()
    end

    if type(path) ~= "string" or path == "" then
        return nil
    end

    return ffiUtil.realpath(path) or path
end

local function pickRandomBookUnderFolder(folder)
    if not folder or lfs.attributes(folder, "mode") ~= "directory" then
        return nil
    end

    local configured = tonumber(G_reader_settings:readSetting("screensaver_max_files")) or 0
    local max_files = math.max(configured, RANDOM_BOOK_COVER_MIN_SCAN_FILES)

    local candidates = {}
    collectDocumentCandidatesSkippingDotDirs(folder, max_files, candidates)

    if #candidates == 0 then
        return nil
    end

    ensureRandomSeeded()
    return candidates[math.random(#candidates)]
end

local function pickRandomBookWithCoverUnderFolder(ui, folder)
    if not ui or not ui.bookinfo then
        return nil
    end

    if not folder or lfs.attributes(folder, "mode") ~= "directory" then
        return nil
    end

    local configured = tonumber(G_reader_settings:readSetting("screensaver_max_files")) or 0
    local max_files = math.max(configured, RANDOM_BOOK_COVER_MIN_SCAN_FILES)

    local candidates = {}
    collectDocumentCandidatesSkippingDotDirs(folder, max_files, candidates)

    if #candidates == 0 then
        return nil
    end

    ensureRandomSeeded()

    local attempts = math.min(#candidates, 80)
    for i = 1, attempts do
        local idx = math.random(#candidates)
        local file = candidates[idx]
        candidates[idx] = candidates[#candidates]
        candidates[#candidates] = nil
        if file then
            local ok, cover_bb = pcall(function()
                return ui.bookinfo:getCoverImage(nil, file)
            end)
            if ok and cover_bb then
                if cover_bb.free then
                    cover_bb:free()
                end
                return file
            end
            if cover_bb and cover_bb.free then
                cover_bb:free()
            end
        end
        if #candidates == 0 then
            break
        end
    end

    return nil
end

local function hasRandomImageFolderConfigured(prefix)
    local settings = G_reader_settings
    local dir = settings:readSetting((prefix or "") .. "screensaver_dir") or settings:readSetting("screensaver_dir")
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then
        return false
    end

    local max_files = settings:readSetting("screensaver_max_files") or 256
    local picked = filemanagerutil.getRandomFile(dir, function(file)
        return DocumentRegistry:isImageFile(file)
    end, max_files)

    return picked ~= nil
end

local function hasCustomImageConfigured()
    local file = G_reader_settings:readSetting("screensaver_document_cover")
    return file and lfs.attributes(file, "mode") == "file"
end

local orig_setup = Screensaver.setup
function Screensaver:setup(event, event_message)
    local prefix = event and (event .. "_") or ""
    local effective_type = getEffectiveScreensaverType(prefix)
    if effective_type ~= RANDOM_BOOK_COVER_MODE then
        self._random_book_cover_enabled = nil
        self._random_book_cover_cover_mode = nil
        return orig_setup(self, event, event_message)
    end

    local ui = getUI()

    ensureRandomBookCoverDefaults()
    self._random_book_cover_enabled = true
    self._random_book_cover_cover_mode = G_reader_settings:readSetting(RANDOM_BOOK_COVER_COVER_MODE_KEY) or RANDOM_BOOK_COVER_COVER_MODE_FIT

    local desired_type
    local desired_document_cover

    if ui and ui.document then
        desired_type = "cover"
    else
        local folder = getFileManagerFolder(ui)
        desired_document_cover = pickRandomBookWithCoverUnderFolder(ui, folder) or pickRandomBookUnderFolder(folder)
        if desired_document_cover then
            desired_type = "document_cover"
        end
    end

    if not desired_type then
        if hasRandomImageFolderConfigured(prefix) then
            desired_type = "random_image"
        elseif hasCustomImageConfigured() then
            desired_type = "document_cover"
        else
            desired_type = "random_image"
        end
    end

    local type_existed, type_old = backupAndOverrideSetting("screensaver_type", desired_type)
    local prefixed_type_key = prefix ~= "" and (prefix .. "screensaver_type") or nil
    local pref_type_existed, pref_type_old
    if prefixed_type_key then
        pref_type_existed, pref_type_old = backupAndOverrideSetting(prefixed_type_key, desired_type)
    end

    local doc_existed, doc_old
    if desired_type == "document_cover" then
        local document_cover_value = desired_document_cover or G_reader_settings:readSetting("screensaver_document_cover")
        if document_cover_value then
            doc_existed, doc_old = backupAndOverrideSetting("screensaver_document_cover", document_cover_value)
        end
    end

    local ok, res = pcall(orig_setup, self, event, event_message)

    if desired_type == "document_cover" and doc_existed ~= nil then
        restoreSetting("screensaver_document_cover", doc_existed, doc_old)
    end
    if prefixed_type_key then
        restoreSetting(prefixed_type_key, pref_type_existed, pref_type_old)
    end
    restoreSetting("screensaver_type", type_existed, type_old)

    if not ok then
        error(res)
    end

    if (self.screensaver_type ~= "cover") and (self.screensaver_type ~= "random_image") then
        return
    end

    if self.screensaver_type == "random_image" and not hasRandomImageFolderConfigured(prefix) and hasCustomImageConfigured() then
        local fallback_type_existed, fallback_type_old = backupAndOverrideSetting("screensaver_type", "document_cover")
        local fallback_pref_existed, fallback_pref_old
        if prefixed_type_key then
            fallback_pref_existed, fallback_pref_old = backupAndOverrideSetting(prefixed_type_key, "document_cover")
        end

        local ok2, err2 = pcall(orig_setup, self, event, event_message)

        if prefixed_type_key then
            restoreSetting(prefixed_type_key, fallback_pref_existed, fallback_pref_old)
        end
        restoreSetting("screensaver_type", fallback_type_existed, fallback_type_old)

        if not ok2 then
            -- no-op
        end
    end
end

local function allowRandomImageFolderForMenu(ui)
    local screensaver_type = G_reader_settings:readSetting("screensaver_type")
    if screensaver_type == "random_image" or screensaver_type == RANDOM_BOOK_COVER_MODE then
        return true
    end

    if screensaver_type == "cover" then
        local may_ignore_book_cover = G_reader_settings:isTrue("screensaver_exclude_on_hold_books")
            or G_reader_settings:isTrue("screensaver_exclude_finished_books")
            or G_reader_settings:isTrue("screensaver_hide_cover_in_filemanager")
            or Screensaver.isExcluded(ui)
        return may_ignore_book_cover
    end

    return false
end

local orig_dofile = _G.dofile
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

            local item_text = _("Show random book cover on sleep screen")
            local cover_mode_text = _("Random book cover mode")

            local random_item_index
            local cover_mode_exists = false

            for i, item in ipairs(wallpaper_submenu) do
                if type(item) == "table" then
                    if item.text == item_text then
                        random_item_index = i
                    elseif item.text == cover_mode_text then
                        cover_mode_exists = true
                    end
                end
            end

            if not random_item_index then
                local insert_at = 2
                table.insert(wallpaper_submenu, insert_at, genMenuItem(item_text, "screensaver_type", RANDOM_BOOK_COVER_MODE))
                random_item_index = insert_at
            end

            if not cover_mode_exists then
                ensureRandomBookCoverDefaults()

                local enabled_cover_mode = function()
                    return G_reader_settings:readSetting("screensaver_type") == RANDOM_BOOK_COVER_MODE
                end

                table.insert(wallpaper_submenu, random_item_index + 1, {
                    text = cover_mode_text,
                    enabled_func = enabled_cover_mode,
                    sub_item_table = {
                        genMenuItem(_("Fit"), RANDOM_BOOK_COVER_COVER_MODE_KEY, RANDOM_BOOK_COVER_COVER_MODE_FIT, enabled_cover_mode),
                        genMenuItem(_("Stretch"), RANDOM_BOOK_COVER_COVER_MODE_KEY, RANDOM_BOOK_COVER_COVER_MODE_STRETCH, enabled_cover_mode),
                        genMenuItem(_("Center"), RANDOM_BOOK_COVER_COVER_MODE_KEY, RANDOM_BOOK_COVER_COVER_MODE_CENTER, enabled_cover_mode),
                    },
                })
            end

            local border_text = _("Border fill, rotation, and fit")
            local custom_images_text = _("Custom images")

            for i, item in ipairs(wallpaper_submenu) do
                if type(item) == "table" and item.text == border_text and type(item.enabled_func) == "function" then
                    local orig_enabled = item.enabled_func
                    item.enabled_func = function()
                        if G_reader_settings:readSetting("screensaver_type") == RANDOM_BOOK_COVER_MODE then
                            return true
                        end
                        return orig_enabled()
                    end
                elseif type(item) == "table" and item.text == custom_images_text and type(item.enabled_func) == "function" then
                    item.enabled_func = function()
                        local ui_instance = getUI()
                        return allowRandomImageFolderForMenu(ui_instance) or G_reader_settings:readSetting("screensaver_type") == "document_cover"
                    end

                    if item.sub_item_table then
                        for j, sub in ipairs(item.sub_item_table) do
                            if type(sub) == "table" and sub.text == _("Choose random image folder") and type(sub.enabled_func) == "function" then
                                sub.enabled_func = function()
                                    local ui_instance = getUI()
                                    return allowRandomImageFolderForMenu(ui_instance)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return result
end
