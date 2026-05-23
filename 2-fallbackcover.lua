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
                bookinfo.cover_bb     = cached:copy()
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
