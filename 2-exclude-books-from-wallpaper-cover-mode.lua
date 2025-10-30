-- Wallpaper cover exclusions patch
-- For listed books, swap the cover used in wallpaper "book cover" mode with a
-- random image from the folder configured via "Choose random image folder".
-- Books can be listed individually or via directory prefixes. Optionally, a
-- text file named "wallpaper-cover-exclude.txt" can be created in the KOReader
-- patches folder; each non-empty, non-comment line will be read on startup.
-- Lines ending with a slash (/) are treated as directory prefixes.

local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Screensaver = require("ui/screensaver")
local util = require("util")

local CONFIG_FILE_NAME = "wallpaper-cover-exclude.txt"

local LISTED_ITEMS = {
    files = { -- absolute file paths. Example:
        -- "/mnt/us/documents/Books/MyBook.epub",--for Kindle
        -- "/mnt/onboard/Books/MyBook.pdf",--for Kobo
    },
    directories = { -- directory prefixes. Example:
        -- "/mnt/us/documents/Books/SeriesFolder/", --for Kindle
        -- "/mnt/onboard/Books/",--for Kobo
    },
}

local function trim(line)
    return line and line:match("^%s*(.-)%s*$") or line
end

local function loadConfigFromFile()
    local data_dir = DataStorage:getDataDir()
    local config_path = data_dir and (data_dir .. "/patches/" .. CONFIG_FILE_NAME)
    if not config_path then
        return
    end

    local fh = io.open(config_path, "r")
    if not fh then
        return
    end

    for line in fh:lines() do
        line = trim(line)
        if line and line ~= "" and not line:match("^#") then
            if line:sub(-1) == "/" then
                table.insert(LISTED_ITEMS.directories, line)
            else
                table.insert(LISTED_ITEMS.files, line)
            end
        end
    end

    fh:close()
end

loadConfigFromFile()

LISTED_ITEMS.files = LISTED_ITEMS.files or {}
LISTED_ITEMS.directories = LISTED_ITEMS.directories or {}

local listed_files = {}
local listed_directories_map = {}
local listed_directories = {}

local function ensureForwardSlashes(path)
    return path and path:gsub("\\", "/") or path
end

local function ensureTrailingSlash(path)
    if not path or path == "" then
        return path
    end
    path = ensureForwardSlashes(path)
    path = path:gsub("/+", "/")
    path = path:gsub("/$", "")
    return path .. "/"
end

local function safeRealpath(path)
    if not path or path == "" then
        return nil
    end
    local ok, resolved = pcall(ffiUtil.realpath, path)
    if ok and resolved and resolved ~= "" then
        return resolved
    end
end

local function normalizeFilePath(path)
    if not path or path == "" then
        return nil
    end
    path = ensureForwardSlashes(path)
    local resolved = safeRealpath(path)
    if resolved then
        return ensureForwardSlashes(resolved)
    end
    return path
end

local function normalizeDirectoryPath(path)
    if not path or path == "" then
        return nil
    end
    local normalized = normalizeFilePath(path)
    if normalized then
        return ensureTrailingSlash(normalized)
    end
    return ensureTrailingSlash(ensureForwardSlashes(path))
end

local function addFileEntry(path)
    if not path or path == "" then
        return
    end
    local candidates = {}
    local normalized = normalizeFilePath(path)
    if normalized then
        table.insert(candidates, normalized)
    end
    local fallback = ensureForwardSlashes(path)
    if fallback and fallback ~= normalized then
        table.insert(candidates, fallback)
    end
    for _, candidate in ipairs(candidates) do
        if candidate and not listed_files[candidate] then
            listed_files[candidate] = true
        end
    end
end

local function addDirectoryEntry(path)
    if not path or path == "" then
        return
    end
    local candidates = {}
    local normalized = normalizeDirectoryPath(path)
    if normalized then
        table.insert(candidates, normalized)
    end
    local fallback = ensureTrailingSlash(ensureForwardSlashes(path))
    if fallback and fallback ~= normalized then
        table.insert(candidates, fallback)
    end
    for _, candidate in ipairs(candidates) do
        if candidate and not listed_directories_map[candidate] then
            listed_directories_map[candidate] = true
            table.insert(listed_directories, candidate)
        end
    end
end

for _, path in ipairs(LISTED_ITEMS.files) do
    addFileEntry(path)
end

for _, path in ipairs(LISTED_ITEMS.directories) do
    addDirectoryEntry(path)
end

local function isListedBook(path)
    if not path or path == "" then
        return false
    end
    local normalized = normalizeFilePath(path)
    if normalized and listed_files[normalized] then
        return true
    end
    local fallback = ensureForwardSlashes(path)
    if fallback and listed_files[fallback] then
        return true
    end
    for _, dir in ipairs(listed_directories) do
        if normalized and util.stringStartsWith(normalized, dir) then
            return true
        end
        if util.stringStartsWith(fallback, dir) then
            return true
        end
    end
    return false
end

local function pickRandomImage(dir)
    if not dir or dir == "" then
        return nil
    end
    dir = ensureForwardSlashes(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then
        return nil
    end
    local match_func = function(file)
        return not util.stringStartsWith(ffiUtil.basename(file), "._")
            and DocumentRegistry:isImageFile(file)
    end
    if G_reader_settings:isTrue("screensaver_cycle_images_alphabetically") then
        local files = {}
        local count = 0
        util.findFiles(dir, function(file)
            if count >= 128 then
                return
            end
            if match_func(file) then
                count = count + 1
                table.insert(files, file)
            end
        end, false)
        if #files == 0 then
            return nil
        end
        local sort = require("sort")
        local natsort = sort.natsort_cmp()
        table.sort(files, function(a, b)
            return natsort(a, b)
        end)
        local index = (G_reader_settings:readSetting("screensaver_cycle_index", 0) or 0) + 1
        if index > #files then
            index = 1
        end
        G_reader_settings:saveSetting("screensaver_cycle_index", index)
        return files[index]
    end
    return filemanagerutil.getRandomFile(dir, match_func)
end

local function resolveScreensaverDir(self)
    if self.prefix and self.prefix ~= "" then
        local prefixed = G_reader_settings:readSetting(self.prefix .. "screensaver_dir")
        if prefixed and prefixed ~= "" then
            return prefixed
        end
    end
    return G_reader_settings:readSetting("screensaver_dir")
end

Screensaver.setup = (function(original)
    return function(self, event, event_message)
        original(self, event, event_message)

        if self.screensaver_type ~= "cover" then
            return
        end

        local lastfile = G_reader_settings:readSetting("lastfile")
        if not isListedBook(lastfile) then
            return
        end

        local screensaver_dir = resolveScreensaverDir(self)
        if not screensaver_dir or screensaver_dir == "" then
            return
        end

        local random_image = pickRandomImage(screensaver_dir)
        if not random_image then
            return
        end

        if self.image and self.image.free then
            self.image:free()
        end
        self.image = nil
        self.image_file = random_image
        logger.dbg("WallpaperCoverPatch: using random image for listed book", lastfile, random_image)
    end
end)(Screensaver.setup)

