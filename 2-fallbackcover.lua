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

-- Set to a folder path to pick a random image per book instead of a single file.
-- e.g. "/mnt/onboard/fallback_covers"  (overrides FALLBACK_IMAGE_PATH when set)
-- Each book is assigned a consistent image (same book → same image across sessions).
local FALLBACK_IMAGE_FOLDER = nil

-- Set to true to overlay the book title (and optionally author) on the cover.
local SHOW_TITLE  = true
local SHOW_AUTHOR = true   -- only used when SHOW_TITLE is also true

-- Title text style
local TITLE_COLOR    = "black"  -- "black" or "white"
local TITLE_BOLD     = true
local TITLE_FONT     = "cfont"  -- e.g. "cfont", "tfont", or any font name in KOReader
local TITLE_MIN_SIZE = 12       -- minimum font size; text is truncated with ... below this
local TITLE_MAX_SIZE = 24       -- maximum font size in pixels (scaled down for small covers)

-- Author text style
local AUTHOR_COLOR    = "black"  -- "black" or "white"
local AUTHOR_BOLD     = false
local AUTHOR_FONT     = "cfont"
local AUTHOR_MIN_SIZE = 10       -- minimum font size
local AUTHOR_MAX_SIZE = 18       -- maximum font size in pixels

-- Comma-separated list of path prefixes to restrict fallback covers to.
-- When set, fallback is applied ONLY to books whose filepath starts with one
-- of these prefixes. Leave empty ("") to apply to all books.
-- e.g. "/mnt/onboard/books,/mnt/onboard/My Documents"
local APPLY_ONLY_TO = ""

-- Comma-separated list of path substrings to exclude from fallback covers.
-- If a book's filepath contains any of these strings, the fallback is skipped.
-- e.g. "/mnt/onboard/RSS,instapaper,cache"
local EXCLUDE_PATHS = ""

-- When a book has no title metadata, use the filename (without extension) as
-- the title, replacing hyphens and underscores with spaces.
local USE_FILENAME_AS_TITLE = true
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

local image_path = nil
local _use_folder = false

if FALLBACK_IMAGE_FOLDER then
    if lfs.attributes(FALLBACK_IMAGE_FOLDER, "mode") == "directory" then
        _use_folder = true
    else
        logger.warn("FallbackCover patch: folder not found:", FALLBACK_IMAGE_FOLDER)
    end
end

if not _use_folder then
    image_path = findFallbackImage()
end

if not _use_folder and not image_path then
    return  -- nothing to do
end

-- ── Defer patching until after plugins have loaded ───────────────────────────
-- applyPatches("2") runs right after UIManager is created, but *before*
-- FileManager initialises and loads plugins (including CoverBrowser).
-- Scheduling with delay=0 pushes the actual patching to the first event-loop
-- tick, by which time all plugins and bookinfomanager are in package.loaded.
-- If bookinfomanager is still not available (non-standard installs / slow
-- plugin init), the patch retries up to MAX_RETRIES times with RETRY_DELAY
-- seconds between attempts before giving up.

local UIManager   = require("ui/uimanager")
local MAX_RETRIES = 5
local RETRY_DELAY = 2  -- seconds between retries

local function applyPatch(attempt)

    -- ── Load BookInfoManager (with retry on failure) ────────────────────────

    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or not BookInfoManager then
        if attempt < MAX_RETRIES then
            logger.warn(string.format(
                "FallbackCover patch: CoverBrowser not available yet, retry %d/%d in %ds",
                attempt, MAX_RETRIES, RETRY_DELAY))
            UIManager:scheduleIn(RETRY_DELAY, function() applyPatch(attempt + 1) end)
        else
            logger.warn("FallbackCover patch: CoverBrowser not available after",
                        MAX_RETRIES, "attempts, giving up:", BookInfoManager)
        end
        return
    end

    -- ── Cache helpers ────────────────────────────────────────────────────

    -- Single-file mode: cache one blitbuffer for the session
    local _cached_bb      = nil
    local _cached_bb_path = nil

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

    -- Folder mode: cache file list + one blitbuffer per image path
    local _folder_file_list = nil   -- cached sorted list of image paths
    local _folder_bb_cache  = {}    -- path → blitbuffer (or false on failure)

    local function getFolderFileList()
        if _folder_file_list ~= nil then return _folder_file_list end
        local supported = { jpg=true, jpeg=true, png=true, bmp=true, gif=true, webp=true }
        local list = {}
        -- lfs.dir raises on failure; guard with lfs.attributes first
        if lfs.attributes(FALLBACK_IMAGE_FOLDER, "mode") == "directory" then
            for entry in lfs.dir(FALLBACK_IMAGE_FOLDER) do
                if entry ~= "." and entry ~= ".." then
                    local ext = entry:match("%.(%w+)$")
                    if ext and supported[ext:lower()] then
                        table.insert(list, FALLBACK_IMAGE_FOLDER .. "/" .. entry)
                    end
                end
            end
        end
        table.sort(list)  -- sort for determinism
        _folder_file_list = list
        if #list == 0 then
            logger.warn("FallbackCover patch: no images found in", FALLBACK_IMAGE_FOLDER)
        else
            logger.info("FallbackCover patch: found", #list, "images in", FALLBACK_IMAGE_FOLDER)
        end
        return _folder_file_list
    end

    local function getBBForBook(filepath)
        local list = getFolderFileList()
        if #list == 0 then return nil end

        -- Deterministic hash: same book filepath → same image every session
        local hash = 0
        for i = 1, #filepath do
            hash = (hash * 31 + string.byte(filepath, i)) % 1000003
        end
        local chosen = list[(hash % #list) + 1]

        -- Lazy-load and cache per image path
        if _folder_bb_cache[chosen] == nil then
            local RenderImage = require("ui/renderimage")
            local ok2, bb = pcall(RenderImage.renderImageFile, RenderImage, chosen, false)
            _folder_bb_cache[chosen] = (ok2 and bb) and bb or false
            if ok2 and bb then
                logger.info("FallbackCover patch: loaded", chosen)
            else
                logger.warn("FallbackCover patch: failed to load", chosen)
            end
        end

        return _folder_bb_cache[chosen] or nil
    end

    -- Unified entry point
    local function getFallbackBB(filepath)
        if _use_folder then
            return getBBForBook(filepath)
        else
            return getCachedBB()
        end
    end

    -- ── Text overlay helper ───────────────────────────────────────────────

    local function renderTextOnCover(bb, title, author)
        local ok_f,  Font       = pcall(require, "ui/font")
        local ok_r,  RenderText = pcall(require, "ui/rendertext")
        local ok_bl, Blitbuffer = pcall(require, "ffi/blitbuffer")
        if not (ok_f and ok_r and ok_bl) then return end

        local function toColor(name)
            return (name == "white") and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        end

        local W   = bb:getWidth()
        local H   = bb:getHeight()
        local pad = math.max(4, math.floor(H * 0.03))
        local max_w = W - pad * 2

        -- Initial font sizes: proportional to cover height, capped by config
        local t_size = math.max(TITLE_MIN_SIZE,  math.min(TITLE_MAX_SIZE,  math.floor(H / 8)))
        local a_size = math.max(AUTHOR_MIN_SIZE, math.min(AUTHOR_MAX_SIZE, math.floor(H / 11)))

        -- Shrink-to-fit: find the widest word at current size; if it overflows,
        -- decrease size one step at a time until it fits or MIN_SIZE is reached.
        local function shrinkToFit(text, font_name, size, min_size, bold)
            local face_cur  = Font:getFace(font_name, size)
            local widest_w  = 0
            local widest_wd = ""
            for w in text:gmatch("%S+") do
                local ww = RenderText:sizeUtf8Text(0, false, face_cur, w, false, bold).x
                if ww > widest_w then widest_w = ww ; widest_wd = w end
            end
            if widest_w <= max_w then return size end  -- already fits, no shrink needed
            while size > min_size do
                size = size - 1
                local ww = RenderText:sizeUtf8Text(
                    0, false, Font:getFace(font_name, size), widest_wd, false, bold).x
                if ww <= max_w then break end
            end
            return size
        end

        t_size = shrinkToFit(title, TITLE_FONT, t_size, TITLE_MIN_SIZE, TITLE_BOLD)
        if author and SHOW_AUTHOR then
            a_size = shrinkToFit(author, AUTHOR_FONT, a_size, AUTHOR_MIN_SIZE, AUTHOR_BOLD)
        end

        local t_face = Font:getFace(TITLE_FONT,  t_size)
        local a_face = (author and SHOW_AUTHOR) and Font:getFace(AUTHOR_FONT, a_size) or nil

        -- Word-wrap helper: splits text into lines that fit max_w.
        -- Returns array of {text=string, w=number}. Caps at max_lines.
        local function wrapLines(text, face, max_lines, bold)
            local lines  = {}
            local words  = {}
            for w in text:gmatch("%S+") do table.insert(words, w) end

            local space_w  = RenderText:sizeUtf8Text(0, false, face, " ", false, bold).x
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
                local word_w = RenderText:sizeUtf8Text(0, false, face, word, false, bold).x
                if word_w > max_w then
                    flush()
                    if #lines < max_lines then
                        word   = RenderText:truncateTextByWidth(word, face, max_w, false, bold)
                        word_w = RenderText:sizeUtf8Text(0, false, face, word, false, bold).x
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
        local t_ref  = RenderText:sizeUtf8Text(0, false, t_face, "Ag", false, TITLE_BOLD)
        local t_ln_h = t_ref.y_top + t_ref.y_bottom
        local line_gap = math.max(2, math.floor(t_size * 0.2))

        local a_ref, a_ln_h
        if a_face then
            a_ref  = RenderText:sizeUtf8Text(0, false, a_face, "Ag", false, AUTHOR_BOLD)
            a_ln_h = a_ref.y_top + a_ref.y_bottom
        end

        -- Wrap: title up to 3 lines, author up to 1 line
        local t_lines = wrapLines(title,  t_face, 3, TITLE_BOLD)
        local a_lines = (a_face and #t_lines > 0)
                        and wrapLines(author, a_face, 1, AUTHOR_BOLD) or {}

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
                                      false, TITLE_BOLD, toColor(TITLE_COLOR))
            cur_y = cur_y + t_ln_h + (i < #t_lines and line_gap or 0)
        end

        -- Render author line(s) below title
        if #a_lines > 0 then
            cur_y = cur_y + pad
            for i, line in ipairs(a_lines) do
                local x = math.max(pad, math.floor((W - line.w) / 2))
                RenderText:renderUtf8Text(bb, x, cur_y + a_ref.y_top, a_face, line.text,
                                          false, AUTHOR_BOLD, toColor(AUTHOR_COLOR))
                cur_y = cur_y + a_ln_h + (i < #a_lines and line_gap or 0)
            end
        end
    end

    -- ── Build path filters ──────────────────────────────────────────────────

    local function parseCSV(str)
        local t = {}
        if str and str ~= "" then
            for segment in str:gmatch("[^,]+") do
                segment = segment:match("^%s*(.-)%s*$")  -- trim whitespace
                if segment ~= "" then table.insert(t, segment) end
            end
        end
        return t
    end

    local _include_list = parseCSV(APPLY_ONLY_TO)
    local _exclude_list = parseCSV(EXCLUDE_PATHS)

    local function isAllowed(filepath)
        -- Inclusion check: if APPLY_ONLY_TO is set, filepath must start with one prefix
        if #_include_list > 0 then
            local ok = false
            for _, prefix in ipairs(_include_list) do
                if filepath:sub(1, #prefix) == prefix then ok = true; break end
            end
            if not ok then return false end
        end
        -- Exclusion check: filepath must not contain any excluded substring
        for _, seg in ipairs(_exclude_list) do
            if filepath:find(seg, 1, true) then return false end
        end
        return true
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
        --   • filepath passes APPLY_ONLY_TO and EXCLUDE_PATHS filters
        if bookinfo
            and get_cover
            and bookinfo.cover_fetched
            and not bookinfo.has_cover
            and not bookinfo.ignore_cover
            and isAllowed(filepath)
        then
            local ok_fb, cached = pcall(getFallbackBB, filepath)
            if not ok_fb then
                logger.warn("FallbackCover patch: getFallbackBB failed:", cached)
                cached = nil
            end
            if cached then
                -- Determine display title: metadata title, or filename as fallback
                local display_title = bookinfo.title
                if not display_title and USE_FILENAME_AS_TITLE then
                    local fname = filepath:match("([^/]+)$") or ""
                    fname = fname:match("^(.+)%.[^%.]+$") or fname  -- strip extension
                    display_title = fname:gsub("[-_]", " ")
                end
                local cover_bb = cached:copy()
                if SHOW_TITLE and display_title and display_title ~= "" then
                    local ok_txt = pcall(renderTextOnCover, cover_bb,
                                        display_title,
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
end

UIManager:scheduleIn(0, function() applyPatch(1) end)
