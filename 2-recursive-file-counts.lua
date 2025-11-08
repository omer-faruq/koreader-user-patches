local FileChooser = require("ui/widget/filechooser")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template

local original_getMenuItemMandatory = FileChooser.getMenuItemMandatory
local original_refreshPath = FileChooser.refreshPath

local function computeRecursiveFileCounts(self, path, counts, visited)
    if visited[path] then
        return 0
    end
    visited[path] = true

    if counts[path] ~= nil then
        return counts[path]
    end

    local total = 0
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then
        counts[path] = 0
        return 0
    end

    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." and (FileChooser.show_hidden or not util.stringStartsWith(entry, ".")) then
            local fullpath = path .. "/" .. entry
            local attr = lfs.attributes(fullpath) or {}
            if attr.mode == "directory" then
                if self:show_dir(entry) then
                    total = total + computeRecursiveFileCounts(self, fullpath, counts, visited)
                end
            elseif attr.mode == "file" then
                if not util.stringStartsWith(entry, "._") and self:show_file(entry, fullpath) then
                    total = total + 1
                end
            end
        end
    end

    counts[path] = total
    return total
end

local function getRecursiveFileCount(self, path)
    self._recursive_file_counts = self._recursive_file_counts or {}
    return computeRecursiveFileCounts(self, path, self._recursive_file_counts, {})
end

function FileChooser:getMenuItemMandatory(item, collate)
    if collate then
        return original_getMenuItemMandatory(self, item, collate)
    end

    local sub_dirs, dir_files = self:getList(item.path)
    local direct_files = #dir_files
    local total_files = getRecursiveFileCount(self, item.path)

    local text
    if total_files > direct_files then
        text = T("%1(%2) \u{F016}", direct_files, total_files)
    else
        text = T("%1 \u{F016}", direct_files)
    end

    if #sub_dirs > 0 then
        text = T("%1 \u{F114} ", #sub_dirs) .. text
    end

    local FileManagerShortcuts = require("apps/filemanager/filemanagershortcuts")
    if FileManagerShortcuts:hasFolderShortcut(item.path) then
        text = "☆ " .. text
    end

    return text
end

function FileChooser:refreshPath()
    self._recursive_file_counts = {}
    return original_refreshPath(self)
end
