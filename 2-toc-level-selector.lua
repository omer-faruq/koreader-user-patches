--[[
    TOC Level Selector Patch
    
    This patch allows users to selectively show/hide specific TOC levels per-book.
    You can hide any combination of levels (h1, h2, h3, etc.) - even hide h1 while
    keeping h2 and h3 visible.
    
    Unlike the existing toc_ticks_ignored_levels which only affects progress bars,
    this completely removes selected TOC entries from all system components
    (statistics, footer, TOC viewer, navigation, etc.).
    
    Settings are saved per-book and persist across sessions.
]]

local ReaderToc = require("apps/reader/modules/readertoc")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local CheckButton = require("ui/widget/checkbutton")
local ButtonDialog = require("ui/widget/buttondialog")

-- Store original methods
local original_fillToc = ReaderToc.fillToc
local original_onReadSettings = ReaderToc.onReadSettings
local original_onSaveSettings = ReaderToc.onSaveSettings
local original_addToMainMenu = ReaderToc.addToMainMenu

-- Override onReadSettings to load hidden depths
function ReaderToc:onReadSettings(config)
    original_onReadSettings(self, config)
    self.toc_hidden_depths = config:readSetting("toc_hidden_depths") or {}
end

-- Override onSaveSettings to save hidden depths
function ReaderToc:onSaveSettings()
    original_onSaveSettings(self)
    self.ui.doc_settings:saveSetting("toc_hidden_depths", self.toc_hidden_depths)
end

-- Filter TOC entries based on hidden depths and adjust remaining depths
function ReaderToc:filterTocByHiddenDepths(toc)
    if not toc or #toc == 0 then
        return toc
    end
    
    if not self.toc_hidden_depths or not next(self.toc_hidden_depths) then
        return toc
    end
    
    -- First, collect all actual depths present in the TOC
    local depths_present = {}
    for _, item in ipairs(toc) do
        if item and item.depth and type(item.depth) == "number" and item.depth > 0 then
            depths_present[item.depth] = true
        end
    end
    
    -- Safety check: if no valid depths found, return original
    if not next(depths_present) then
        return toc
    end
    
    -- Build a mapping of old depth -> new depth based on which depths are visible
    local depth_mapping = {}
    local new_depth = 1
    
    -- Find all depths (in order) and create mapping only for visible ones
    local max_depth = 0
    for depth_num, _ in pairs(depths_present) do
        if depth_num > max_depth then
            max_depth = depth_num
        end
    end
    
    -- Safety check: ensure max_depth is valid
    if max_depth < 1 then
        return toc
    end
    
    -- Create mapping for depths that exist and aren't hidden
    for old_depth = 1, max_depth do
        if depths_present[old_depth] and not self.toc_hidden_depths[old_depth] then
            depth_mapping[old_depth] = new_depth
            new_depth = new_depth + 1
        end
    end
    
    -- Filter and remap depths
    local filtered_toc = {}
    
    for i, item in ipairs(toc) do
        if item and item.depth and type(item.depth) == "number" then
            local original_depth = item.depth
            local is_hidden = self.toc_hidden_depths[original_depth]
            
            if not is_hidden then
                -- Create a new item with adjusted depth
                local new_item = {}
                for k, v in pairs(item) do
                    new_item[k] = v
                end
                local new_depth = depth_mapping[original_depth] or original_depth
                new_item.depth = new_depth
                
                table.insert(filtered_toc, new_item)
            end
        end
    end
    
    return filtered_toc
end

-- Override fillToc to apply filtering
function ReaderToc:fillToc()
    -- Call original first
    original_fillToc(self)
    
    -- Ensure toc_hidden_depths is initialized
    self.toc_hidden_depths = self.toc_hidden_depths or {}
    
    -- Only proceed if we have a valid TOC
    if not self.toc or #self.toc == 0 then
        return
    end
    
    -- Store original TOC ONLY on first call
    if not self.toc_original then
        self.toc_original = {}
        for i = 1, #self.toc do
            local item = self.toc[i]
            if item and item.depth then
                self.toc_original[i] = {
                    depth = item.depth,
                    page = item.page,
                    title = item.title,
                }
            end
        end
    end
    
    -- Only apply filtering if we have hidden depths configured
    if self.toc_hidden_depths and next(self.toc_hidden_depths) then
        local ok, filtered = pcall(self.filterTocByHiddenDepths, self, self.toc_original)
        if ok and filtered then
            -- Allow empty TOC if all levels are hidden
            self.toc = filtered
        end
    end
    
    -- Clear toc_ticks_ignored_levels to prevent double filtering
    self.toc_ticks_ignored_levels = {}
end

-- Get original max depth from unfiltered TOC
function ReaderToc:getOriginalMaxDepth()
    if not self.toc_original or #self.toc_original == 0 then
        return 0
    end
    
    local max_depth = 0
    for _, item in ipairs(self.toc_original) do
        if item.depth > max_depth then
            max_depth = item.depth
        end
    end
    return max_depth
end

-- Get original ticks from unfiltered TOC
function ReaderToc:getOriginalTocTicks()
    if not self.toc_original or #self.toc_original == 0 then
        return {}
    end
    
    local ticks = {}
    for _, item in ipairs(self.toc_original) do
        if not ticks[item.depth] then
            ticks[item.depth] = {}
        end
        table.insert(ticks[item.depth], item.page)
    end
    
    for k, _ in ipairs(ticks) do
        table.sort(ticks[k])
    end
    
    return ticks
end

-- Show dialog to configure hidden depths using ButtonDialog
function ReaderToc:showHiddenDepthsDialog()
    -- Close existing dialog if any
    if self.toc_level_dialog then
        UIManager:close(self.toc_level_dialog)
        self.toc_level_dialog = nil
    end
    
    if not self.toc_original then
        self:fillToc()
    end
    
    if not self.toc_original or #self.toc_original == 0 then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("No table of contents available for this book."),
        })
        return
    end
    
    local max_depth = self:getOriginalMaxDepth()
    if max_depth == 0 then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Table of contents has no depth levels."),
        })
        return
    end
    
    local ticks = self:getOriginalTocTicks()
    local buttons = {}
    
    -- Add header
    table.insert(buttons, {{
        text = _("Select which TOC levels to show:"),
        enabled = false,
    }})
    
    -- Add toggle buttons for each depth
    for depth = 1, max_depth do
        local count = ticks[depth] and #ticks[depth] or 0
        local is_hidden = self.toc_hidden_depths[depth] or false
        local status = is_hidden and "✗ HIDDEN" or "✓ visible"
        
        table.insert(buttons, {{
            text = string.format("h%d (depth %d): %d entries - %s", depth, depth, count, status),
            callback = function()
                -- Toggle visibility
                if self.toc_hidden_depths[depth] then
                    self.toc_hidden_depths[depth] = nil
                else
                    self.toc_hidden_depths[depth] = true
                end
                -- Reopen dialog to show updated status
                UIManager:scheduleIn(0.05, function()
                    self:showHiddenDepthsDialog()
                end)
            end,
        }})
    end
    
    -- Add separator and action buttons
    table.insert(buttons, {})
    
    table.insert(buttons, {{
        text = _("Reset all to visible"),
        callback = function()
            self.toc_hidden_depths = {}
            UIManager:scheduleIn(0.05, function()
                self:showHiddenDepthsDialog()
            end)
        end,
    }})
    
    table.insert(buttons, {{
        text = _("Apply changes"),
        callback = function()
            if self.toc_level_dialog then
                UIManager:close(self.toc_level_dialog)
                self.toc_level_dialog = nil
            end
            
            -- Save settings immediately
            self.ui.doc_settings:saveSetting("toc_hidden_depths", self.toc_hidden_depths)
            self.ui.doc_settings:flush()
            
            -- Reset and rebuild TOC with new filter
            self.toc_original = nil  -- Force rebuild from scratch
            self:resetToc()
            self:fillToc()
            
            -- Update footer
            if self.view and self.view.footer then
                self.view.footer:onUpdateFooter(self.view.footer_visible)
            end
            
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Applied. Open TOC menu to see changes."),
                timeout = 2,
            })
        end,
    }})
    
    local ButtonDialog = require("ui/widget/buttondialog")
    self.toc_level_dialog = ButtonDialog:new{
        title = _("TOC Level Selector"),
        buttons = buttons,
    }
    UIManager:show(self.toc_level_dialog)
end

-- Add menu item to configure hidden depths
function ReaderToc:addToMainMenu(menu_items)
    original_addToMainMenu(self, menu_items)
    
    menu_items.toc_hidden_depths_config = {
        text = _("Select visible TOC levels"),
        help_text = _([[Choose which TOC levels (h1, h2, h3, etc.) to show or hide for this book.

Unlike the progress bar tick filter, this removes entries from the entire system including:
• Table of contents viewer
• Chapter navigation
• Footer chapter titles
• Statistics
• All other TOC-based features

Settings are saved per-book and persist across sessions.]]),
        enabled_func = function()
            -- Check original TOC, not filtered one
            original_fillToc(self)
            local has_toc = self.toc and #self.toc > 0
            -- Reset to get filtered version
            self:resetToc()
            return has_toc
        end,
        callback = function()
            self:showHiddenDepthsDialog()
        end,
        separator = true,
    }
end

return "TOC Level Selector patch loaded successfully"
