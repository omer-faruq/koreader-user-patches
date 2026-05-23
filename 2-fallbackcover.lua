--[[
Fallback Cover Image Patch
==========================
Displays a user-chosen image as cover for any book that has no embedded
cover art, in both mosaic and list CoverBrowser modes.

Installation
------------
1. Copy this file into:  koreader/patches/2-fallbackcover.lua
2. Place your fallback cover image in the same patches/ folder.
   Supported filenames (in order of priority):
     fallbackcover.jpg  |  fallbackcover.png  |  fallbackcover.bmp
     fallbackcover.gif  |  fallbackcover.webp

That's it – no editing required.

Alternatively, set FALLBACK_IMAGE_PATH below to an absolute path and leave
the image anywhere you like.

Requirements
------------
- KOReader's CoverBrowser plugin must be enabled.
- Priority "2" ensures the patch runs after UIManager is ready and after
  all plugins (including CoverBrowser) have been loaded.

Version: 1.0.0
--]]

-- ─── CONFIGURATION ──────────────────────────────────────────────────────────
-- Leave as nil to auto-detect from the patches/ folder (recommended).
-- Or set an explicit path, e.g. "/mnt/onboard/covers/default.jpg"
local FALLBACK_IMAGE_PATH = nil

-- Set to true to overlay the book title (and optionally author) on the cover.
local SHOW_TITLE  = true
local SHOW_AUTHOR = true   -- only used when SHOW_TITLE is also true
-- ────────────────────────────────────────────────────────────────────────────

local lfs    = require("libs/libkoreader-lfs")
local logger = require("logger")

-- ── Resolve the image path ───────────────────────────────────────────────────

local function findFallbackImage()
    if FALLBACK_IMAGE_PATH then
        if lfs.attributes(FALLBACK_IMAGE_PATH, "mode") == "file" then
            return FALLBACK_IMAGE_PATH
        end
        logger.warn("FallbackCover patch: configured path not found:", FALLBACK_IMAGE_PATH)
        return nil
    end

    -- Auto-detect: look beside this patch file in patches/
    local DataStorage = require("datastorage")
    local patches_dir = DataStorage:getDataDir() .. "/patches"
    local candidates = {
        "fallbackcover.jpg",
        "fallbackcover.png",
        "fallbackcover.bmp",
        "fallbackcover.gif",
        "fallbackcover.webp",
    }
    for _, name in ipairs(candidates) do
        local path = patches_dir .. "/" .. name
        if lfs.attributes(path, "mode") == "file" then
            logger.info("FallbackCover patch: found image at", path)
            return path
        end
    end

    logger.info("FallbackCover patch: no fallback image found, patch inactive")
    return nil
end

local image_path = findFallbackImage()
if not image_path then
    return  -- nothing to do
end

-- ── Defer patching until after plugins have loaded ───────────────────────────
-- applyPatches("2") runs right after UIManager is created, but *before*
-- FileManager initialises and loads plugins (including CoverBrowser).
-- Scheduling with delay=0 pushes the actual patching to the first event-loop
-- tick, by which time all plugins and bookinfomanager are in package.loaded.

local UIManager = require("ui/uimanager")

UIManager:scheduleIn(0, function()

    -- ── Load BookInfoManager ─────────────────────────────────────────────

    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or not BookInfoManager then
        logger.warn("FallbackCover patch: CoverBrowser not available:", BookInfoManager)
        return
    end

    -- ── Cache helpers ────────────────────────────────────────────────────

    local _cached_bb      = nil   -- loaded blitbuffer
    local _cached_bb_path = nil   -- path it was loaded from

    local function getCachedBB()
        if _cached_bb_path == image_path then
            return _cached_bb
        end

        if _cached_bb then
            _cached_bb:free()
            _cached_bb      = nil
            _cached_bb_path = nil
        end

        local RenderImage = require("ui/renderimage")
        local ok2, bb = pcall(RenderImage.renderImageFile, RenderImage, image_path, false)
        if ok2 and bb then
            _cached_bb      = bb
            _cached_bb_path = image_path
            logger.info("FallbackCover patch: loaded", image_path,
                        bb:getWidth() .. "x" .. bb:getHeight())
        else
            logger.warn("FallbackCover patch: failed to load image:", image_path, bb)
        end

        return _cached_bb
    end

    -- ── Text overlay helper ───────────────────────────────────────────────

    local function renderTextOnCover(bb, title, author)
        local ok_f,  Font       = pcall(require, "ui/font")
        local ok_r,  RenderText = pcall(require, "ui/rendertext")
        local ok_bl, Blitbuffer = pcall(require, "ffi/blitbuffer")
        if not (ok_f and ok_r and ok_bl) then return end

        local W   = bb:getWidth()
        local H   = bb:getHeight()
        local pad = math.max(4, math.floor(H * 0.03))

        -- Font sizes proportional to cover height
        local t_size = math.max(12, math.min(24, math.floor(H / 8)))
        local a_size = math.max(10, math.min(18, math.floor(H / 11)))
        local t_face = Font:getFace("cfont", t_size)
        local a_face = (author and SHOW_AUTHOR) and Font:getFace("cfont", a_size) or nil

        local max_w = W - pad * 2

        -- Word-wrap helper: splits text into lines that fit max_w.
        -- Returns array of {text=string, w=number}. Caps at max_lines.
        local function wrapLines(text, face, max_lines)
            local lines  = {}
            local words  = {}
            for w in text:gmatch("%S+") do table.insert(words, w) end

            local space_w  = RenderText:sizeUtf8Text(0, false, face, " ", false, false).x
            local cur_text = ""
            local cur_w    = 0

            local function flush()
                if cur_text ~= "" then
                    table.insert(lines, { text = cur_text, w = cur_w })
                    cur_text = ""
                    cur_w    = 0
                end
            end

            for _, word in ipairs(words) do
                if #lines >= max_lines then break end
                local word_w = RenderText:sizeUtf8Text(0, false, face, word, false, false).x
                if word_w > max_w then
                    flush()
                    if #lines < max_lines then
                        word   = RenderText:truncateTextByWidth(word, face, max_w, false, false)
                        word_w = RenderText:sizeUtf8Text(0, false, face, word, false, false).x
                        table.insert(lines, { text = word, w = word_w })
                    end
                elseif cur_text == "" then
                    cur_text = word
                    cur_w    = word_w
                elseif cur_w + space_w + word_w <= max_w then
                    cur_text = cur_text .. " " .. word
                    cur_w    = cur_w + space_w + word_w
                else
                    flush()
                    if #lines < max_lines then
                        cur_text = word
                        cur_w    = word_w
                    end
                end
            end
            if #lines < max_lines then flush() end
            return lines
        end

        -- Consistent line metrics using a reference string
        local t_ref  = RenderText:sizeUtf8Text(0, false, t_face, "Ag", false, false)
        local t_ln_h = t_ref.y_top + t_ref.y_bottom
        local line_gap = math.max(2, math.floor(t_size * 0.2))

        local a_ref, a_ln_h
        if a_face then
            a_ref  = RenderText:sizeUtf8Text(0, false, a_face, "Ag", false, false)
            a_ln_h = a_ref.y_top + a_ref.y_bottom
        end

        -- Wrap: title up to 3 lines, author up to 1 line
        local t_lines = wrapLines(title, t_face, 3)
        local a_lines = (a_face and #t_lines > 0)
                        and wrapLines(author, a_face, 1) or {}

        if #t_lines == 0 then return end

        -- Total block height (no trailing gap after last line of each section)
        local block_h = #t_lines * t_ln_h + (#t_lines - 1) * line_gap
        if #a_lines > 0 then
            block_h = block_h + pad + #a_lines * a_ln_h
        end

        -- Vertically center the block
        local cur_y = math.max(pad, math.floor((H - block_h) / 2))

        -- Render title lines
        for i, line in ipairs(t_lines) do
            local x = math.max(pad, math.floor((W - line.w) / 2))
            RenderText:renderUtf8Text(bb, x, cur_y + t_ref.y_top, t_face, line.text,
                                      false, false, Blitbuffer.COLOR_BLACK)
            cur_y = cur_y + t_ln_h + (i < #t_lines and line_gap or 0)
        end

        -- Render author line(s) below title
        if #a_lines > 0 then
            cur_y = cur_y + pad
            for i, line in ipairs(a_lines) do
                local x = math.max(pad, math.floor((W - line.w) / 2))
                RenderText:renderUtf8Text(bb, x, cur_y + a_ref.y_top, a_face, line.text,
                                          false, false, Blitbuffer.COLOR_BLACK)
                cur_y = cur_y + a_ln_h + (i < #a_lines and line_gap or 0)
            end
        end
    end

    -- ── Monkey-patch BookInfoManager.getBookInfo ─────────────────────────

    local orig_getBookInfo = BookInfoManager.getBookInfo

    BookInfoManager.getBookInfo = function(bim, filepath, get_cover)
        local bookinfo = orig_getBookInfo(bim, filepath, get_cover)

        -- Inject fallback only when:
        --   • caller wants a cover
        --   • book was fully indexed  (cover_fetched is set)
        --   • book has no embedded cover  (has_cover is nil/false)
        --   • user has not suppressed the cover  (ignore_cover is nil/false)
        if bookinfo
            and get_cover
            and bookinfo.cover_fetched
            and not bookinfo.has_cover
            and not bookinfo.ignore_cover
        then
            local cached = getCachedBB()
            if cached then
                local cover_bb = cached:copy()
                if SHOW_TITLE and bookinfo.title then
                    local ok_txt = pcall(renderTextOnCover, cover_bb,
                                        bookinfo.title,
                                        SHOW_AUTHOR and bookinfo.authors or nil)
                    if not ok_txt then
                        logger.warn("FallbackCover patch: text overlay failed")
                    end
                end
                bookinfo.cover_bb     = cover_bb
                bookinfo.has_cover    = "Y"
                bookinfo.cover_w      = cached:getWidth()
                bookinfo.cover_h      = cached:getHeight()
                bookinfo.cover_sizetag = cached:getWidth() .. "x" .. cached:getHeight()
            end
        end

        return bookinfo
    end

    logger.info("FallbackCover patch: BookInfoManager.getBookInfo patched, using", image_path)
end)
