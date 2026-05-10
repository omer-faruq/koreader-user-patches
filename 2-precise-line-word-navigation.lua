--[[
Precise Line and Word Navigation for Non-Touch Devices
Enables line-by-line and word-by-word cursor movement for highlight selection on Kindle 4 and similar devices.

Features:
- Up/Down arrows move exactly one line at a time
- Left/Right arrows jump from word to word
- Prevents multi-line/multi-word skipping during navigation
--]]

local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local Geom = require("ui/geometry")
local logger = require("logger")

local original_onMoveHighlightIndicator = ReaderHighlight.onMoveHighlightIndicator
local cached_line_height = nil

function ReaderHighlight:onMoveHighlightIndicator(args)
    if not self.view.visible_area or not self._current_indicator_pos then
        return false
    end

    local dx, dy, quick_move = unpack(args)
    
    if quick_move then
        return original_onMoveHighlightIndicator(self, args)
    end

    local rect = self._current_indicator_pos:copy()
    local center_x = rect.x + rect.w / 2
    local center_y = rect.y + rect.h / 2
    
    if dy ~= 0 then
        local line_height = self:_getConsistentLineHeight(center_x, center_y)
        if line_height then
            local target_y = rect.y + (line_height * dy)
            local aligned_pos = self:_findTextOnLine(center_x, target_y + rect.h / 2, line_height, dy, center_y)
            if aligned_pos then
                rect.y = aligned_pos.y - rect.h / 2
            else
                rect.y = target_y
            end
        else
            rect.y = rect.y + (rect.h * dy)
        end
    elseif dx ~= 0 then
        local next_word_pos = self:_findNextWordPosition(center_x, center_y, dx)
        if next_word_pos then
            rect.x = next_word_pos.x - rect.w / 2
            rect.y = next_word_pos.y - rect.h / 2
        else
            local move_distance = rect.w * dx
            rect.x = rect.x + move_distance
        end
    end

    if rect.x < 0 then
        rect.x = 0
    end
    if rect.x + rect.w > self.view.visible_area.w then
        rect.x = self.view.visible_area.w - rect.w
    end

    local alt_status_bar_height = 0
    if self.ui.rolling and self.ui.document.configurable.status_line == 0 then
        alt_status_bar_height = self.ui.document:getHeaderHeight()
    end
    if rect.y < alt_status_bar_height then
        rect.y = alt_status_bar_height
    end
    
    local footer_height = self.view.footer_visible and self.view.footer:getHeight() or 0
    local status_bar_height = self.ui.rolling and footer_height or 0
    if rect.y + rect.h > self.view.visible_area.h - status_bar_height then
        rect.y = self.view.visible_area.h - status_bar_height - rect.h
    end

    local UIManager = require("ui/uimanager")
    UIManager:setDirty(self.dialog, "ui", self._current_indicator_pos)
    self._current_indicator_pos = rect
    self.view.highlight.indicator = rect
    UIManager:setDirty(self.dialog, "ui", rect)
    
    if self._start_indicator_highlight then
        self:onHoldPan(nil, self:_createHighlightGesture("hold_pan"))
    end
    
    return true
end

function ReaderHighlight:_getConsistentLineHeight(x, y)
    if not self.ui.document.getWordFromPosition then
        return nil
    end
    
    if cached_line_height then
        return cached_line_height
    end
    
    local current_page = self.ui.document:getCurrentPage()
    local heights = {}
    local sample_positions = {
        {x = x, y = y},
        {x = self.view.visible_area.w * 0.3, y = y},
        {x = self.view.visible_area.w * 0.7, y = y},
    }
    
    for _, sample_pos in ipairs(sample_positions) do
        local pos = {x = sample_pos.x, y = sample_pos.y, page = current_page}
        local word_box = self.ui.document:getWordFromPosition(pos, true)
        if word_box and word_box.sbox and word_box.sbox.h > 0 then
            table.insert(heights, word_box.sbox.h)
        end
    end
    
    if #heights > 0 then
        table.sort(heights)
        local median_height = heights[math.ceil(#heights / 2)]
        cached_line_height = median_height
        return median_height
    end
    
    return nil
end

function ReaderHighlight:_findTextOnLine(x, target_y, line_height, direction, current_y)
    if not self.ui.document.getWordFromPosition then
        return nil
    end
    
    local current_page = self.ui.document:getCurrentPage()
    local search_range = line_height or (self._current_indicator_pos.h * 2)
    local vertical_step = search_range / 10
    
    for offset = 0, search_range, vertical_step do
        for sign = 0, 1 do
            local search_y = target_y + (sign == 0 and offset or -offset)
            
            if search_y >= 0 and search_y <= self.view.visible_area.h then
                local horizontal_samples = {
                    x,
                    self.view.visible_area.w * 0.2,
                    self.view.visible_area.w * 0.5,
                    self.view.visible_area.w * 0.8,
                }
                
                for _, sample_x in ipairs(horizontal_samples) do
                    local pos = {x = sample_x, y = search_y, page = current_page}
                    local word_box = self.ui.document:getWordFromPosition(pos, true)
                    
                    if word_box and word_box.sbox then
                        local word_center_y = word_box.sbox.y + word_box.sbox.h / 2
                        local is_in_direction = true
                        
                        if direction and current_y then
                            if direction > 0 then
                                is_in_direction = word_center_y > current_y
                            else
                                is_in_direction = word_center_y < current_y
                            end
                        end
                        
                        if is_in_direction and math.abs(word_center_y - target_y) < search_range then
                            return {x = sample_x, y = word_center_y}
                        end
                    end
                end
            end
            
            if offset == 0 then break end
        end
    end
    
    return nil
end

function ReaderHighlight:_findNextWordPosition(x, y, direction)
    if not self.ui.document.getWordFromPosition then
        return nil
    end
    
    local current_page = self.ui.document:getCurrentPage()
    local search_x = x
    local search_step = self.view.visible_area.w / 50
    local max_attempts = 100
    
    for i = 1, max_attempts do
        search_x = search_x + (search_step * direction)
        
        if search_x < 0 or search_x > self.view.visible_area.w then
            break
        end
        
        local pos = {x = search_x, y = y, page = current_page}
        local word_box = self.ui.document:getWordFromPosition(pos, true)
        
        if word_box and word_box.sbox then
            local word_center_x = word_box.sbox.x + word_box.sbox.w / 2
            local word_center_y = word_box.sbox.y + word_box.sbox.h / 2
            
            if direction > 0 then
                if word_center_x > x + search_step then
                    return {x = word_center_x, y = word_center_y}
                end
            else
                if word_center_x < x - search_step then
                    return {x = word_center_x, y = word_center_y}
                end
            end
        end
    end
    
    return nil
end

logger.info("Precise Line and Word Navigation patch loaded")
