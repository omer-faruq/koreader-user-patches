-- patches/2-ascii-cover-screensaver.lua
--
-- Sleep screen wallpaper: the cover of the current (or last read) book,
-- rendered as ASCII art.
--
-- MENU
--   Settings > Screen > Sleep screen > Wallpaper
--     • "Show ASCII art of book cover on sleep screen"   (radio, type "ascii_cover")
--     • "ASCII cover settings"                           (submenu, enabled when selected)
--         - Exclude paths         comma-separated path fragments; a book whose
--                                 path contains one is skipped and the reading
--                                 history is walked backwards for the first
--                                 book that is not excluded
--         - Quality               columns per line: Auto (default; fixed glyph size,
--                                 columns follow the screen width) / Low 60 / Normal 80 /
--                                 High 120 / Very high 160 / Ultra 200 / custom (40–240)
--         - Character set         simple (12) / detailed (70) / block shading;
--                                 on-device engine only
--         - Bold glyphs           synthetic bold strokes (default on)
--         - Tone                  normal / darker / darkest gamma on luminance;
--                                 on-device engine only
--         - Cover placement       fit (keep aspect, margins) / fill (keep
--                                 aspect, crop overflow) / stretch
--         - Convert on device     offline luminance ramp, no network, no key (default)
--         - Convert with API League
--                                 https://apileague.com Image-to-ASCII API.
--                                 The cover PNG is POSTed straight into the
--                                 request body, so no image hosting is needed.
--                                 Each call costs 5 quota points (free tier: 50/day).
--         - API League key        optional override of the built-in key
--         - Convert current cover now
--         - Clear ASCII cache
--
-- BEHAVIOUR
--   • In the file browser the last opened book is used.
--   • Results are cached as text under <datadir>/cache/ascii_covers/ keyed by
--     the book's partial MD5, the engine, placement and character grid, so a cover is
--     converted once per screen/column setting.
--   • The API engine never touches the network at suspend time. It converts
--     when a book is opened (if WiFi is already connected) or via "Convert
--     current cover now". If no cached API result exists at suspend time the
--     on-device engine is used instead, so the sleep screen is always ASCII.
--   • If no cover can be produced at all, core's normal "book cover" mode
--     (and its random-image fallback) takes over.
--
-- The effective Screensaver.screensaver_type becomes "cover" with a
-- pre-rendered full-screen BlitBuffer in Screensaver.image, so core's own
-- show() draws it (portrait switch, e-ink flash, message overlay all apply).

local Blitbuffer  = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device      = require("device")
local Font        = require("ui/font")
local RenderImage = require("ui/renderimage")
local RenderText  = require("ui/rendertext")
local Screensaver = require("ui/screensaver")
local UIManager   = require("ui/uimanager")
local ffiUtil     = require("ffi/util")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local util        = require("util")
local _           = require("gettext")
local T           = ffiUtil.template
local Screen      = Device.screen

local TYPE            = "ascii_cover"
local KEY_EXCLUDE     = "ascii_cover_exclude_paths"
local KEY_COLUMNS     = "ascii_cover_columns"
local KEY_ENGINE      = "ascii_cover_engine"      -- "local" | "apileague"
local KEY_API_KEY     = "ascii_cover_api_key"
local KEY_FIT         = "ascii_cover_fit"         -- "fit" | "fill" | "stretch"

local DEFAULT_COLUMNS = 80  -- starting value of the custom spinner; quality defaults to "auto"
local MIN_COLUMNS, MAX_COLUMNS = 40, 240
-- Quality presets: label → columns. More columns = finer detail, smaller glyphs.
local QUALITY_PRESETS = {
    { label = _("Low"),       cols = 60  },
    { label = _("Normal"),    cols = 80  },
    { label = _("High"),      cols = 120 },
    { label = _("Very high"), cols = 160 },
    { label = _("Ultra"),     cols = 200 },
}
local DEFAULT_API_KEY = "Your_Api_Key"
local API_URL         = "https://api.apileague.com/convert-image-to-ascii-txt"
local CACHE_DIR       = DataStorage:getDataDir() .. "/cache/ascii_covers"

-- "auto" quality: glyph size stays fixed (in scaled points) and the column
-- count follows the screen width, so bigger/denser screens get more cells.
local AUTO_FONT_SIZE = 9

-- Character ramps, darkest → lightest. Paper is white, so dark pixels get
-- dense glyphs. Lookup cost is identical whatever the ramp length.
local function splitChars(s)
    local t = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
    return t
end
local RAMPS = {
    simple   = splitChars("@%#*+=;:-,. "),
    detailed = splitChars("$@B%8&WM#*oahkbdpqwmZO0QLCJUYXzcvunxrjft/\\|()1{}[]?-_+~<>i!lI;:,\"^`'. "),
    blocks   = splitChars("█▓▒░ "),
}
local KEY_CHARSET = "ascii_cover_charset"      -- "simple" | "detailed" | "blocks"
local KEY_BOLD    = "ascii_cover_bold"         -- synthetic bold glyphs (default on)
local KEY_TONE    = "ascii_cover_tone"         -- "normal" | "darker" | "darkest"
-- Tone = gamma applied to luminance before the ramp lookup; >1 pushes
-- mid-tones toward denser glyphs so the picture reads darker on e-ink.
local TONE_GAMMA = { normal = 1.0, darker = 1.6, darkest = 2.4 }
-- DroidSansMono (KOReader's "infont") has no block-shading glyphs; this
-- optional mono font in koreader/fonts/ does. Falls back to infont if absent.
local BLOCKS_FONT = "JetBrainsMono-Regular.ttf"

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------
-- Unset → auto (default).
local function isAutoColumns()
    local v = G_reader_settings:readSetting(KEY_COLUMNS)
    return v == nil or v == "auto"
end

local function clampColumns(c)
    if c < MIN_COLUMNS then c = MIN_COLUMNS end
    if c > MAX_COLUMNS then c = MAX_COLUMNS end
    return c
end

-- Forward-declared: defined with the font helpers below.
local autoColumns

local function getColumns()
    if isAutoColumns() then
        return clampColumns(autoColumns())
    end
    return clampColumns(tonumber(G_reader_settings:readSetting(KEY_COLUMNS)) or DEFAULT_COLUMNS)
end

local function getCharset()
    local c = G_reader_settings:readSetting(KEY_CHARSET)
    if RAMPS[c] then return c end
    return "simple"
end

local function isBold()
    return G_reader_settings:nilOrTrue(KEY_BOLD)
end

local function getTone()
    local t = G_reader_settings:readSetting(KEY_TONE)
    if TONE_GAMMA[t] then return t end
    return "normal"
end

local function getEngine()
    local e = G_reader_settings:readSetting(KEY_ENGINE)
    if e == "apileague" then return e end
    return "local"
end

local function getFitMode()
    local f = G_reader_settings:readSetting(KEY_FIT)
    if f == "fill" or f == "stretch" then return f end
    return "fit"
end

local function getApiKey()
    local k = G_reader_settings:readSetting(KEY_API_KEY)
    if type(k) == "string" and k ~= "" then return k end
    return DEFAULT_API_KEY
end

local function getExcludes()
    local raw = G_reader_settings:readSetting(KEY_EXCLUDE)
    if type(raw) ~= "string" or raw == "" then return {} end
    local result = {}
    for token in raw:gmatch("[^,\n]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then result[#result + 1] = t end
    end
    return result
end

local function isPathExcluded(fp, excludes)
    if not fp then return true end
    for _i, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- Honour core's per-book "Do not show this book cover on sleep screen" flag.
local function isBookExcluded(fp)
    local ok, BookList = pcall(require, "ui/widget/booklist")
    if not ok or not BookList then return false end
    local ok2, res = pcall(function()
        return BookList.hasBookBeenOpened(fp)
           and BookList.getDocSettings(fp):isTrue("exclude_screensaver")
    end)
    return ok2 and res or false
end

local function fileExists(fp)
    return type(fp) == "string" and lfs.attributes(fp, "mode") == "file"
end

local function getActiveUI()
    return require("apps/reader/readerui").instance
        or require("apps/filemanager/filemanager").instance
end

-- Current book, else last opened book, else walk history backwards past
-- excluded paths.
local function resolveTargetFile(ui)
    local excludes = getExcludes()
    local candidate = ui and ui.document and ui.document.file
                   or G_reader_settings:readSetting("lastfile")
    if fileExists(candidate) and not isPathExcluded(candidate, excludes)
        and not isBookExcluded(candidate) then
        return candidate
    end
    local ok, RH = pcall(require, "readhistory")
    if ok and RH then
        if not (RH.hist and #RH.hist > 0) then
            pcall(function() RH:reload() end)
        end
        for _i, e in ipairs(RH.hist or {}) do
            if e and e.file and e.file ~= candidate and fileExists(e.file)
                and not isPathExcluded(e.file, excludes)
                and not isBookExcluded(e.file) then
                return e.file
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Character grid / font metrics
-- ---------------------------------------------------------------------------
local function getPortraitScreenSize()
    local w, h = Screen:getWidth(), Screen:getHeight()
    if w > h then w, h = h, w end
    return w, h
end

-- Synthetic bold (FT_GlyphSlot_Embolden) widens the advance, so the cell is
-- always measured with the same bold flag it will be rendered with.
local function measureCell(face, width, bold)
    local sz = RenderText:sizeUtf8Text(0, width, face, "M", false, bold)
    local cw = sz and sz.x or 0
    if cw <= 0 then cw = 1 end
    return cw
end

-- Mono face for the current charset. Block shading needs a font that has
-- U+2588..U+2591; everything else uses KOReader's bundled DroidSansMono.
local blocks_font_available -- nil = not probed yet
local function getMonoFace(size)
    if getCharset() == "blocks" and blocks_font_available ~= false then
        local ok, face = pcall(Font.getFace, Font, BLOCKS_FONT, size)
        if ok and face then
            blocks_font_available = true
            return face
        end
        blocks_font_available = false
        logger.warn("ascii cover: " .. BLOCKS_FONT .. " not found, block shading will use fallback glyphs")
    end
    return Font:getFace("infont", size)
end

-- "auto" quality: how many AUTO_FONT_SIZE glyphs fit across the screen.
autoColumns = function()
    local screen_w = getPortraitScreenSize()
    local face = getMonoFace(AUTO_FONT_SIZE)
    return math.floor(screen_w / measureCell(face, screen_w, isBold()))
end

-- Picks the mono font size so that `cols` characters span `width` pixels.
local function getMetrics()
    local screen_w, screen_h = getPortraitScreenSize()
    local cols = getColumns()

    local bold = isBold()
    local size, face, cell_w
    if isAutoColumns() then
        size = AUTO_FONT_SIZE
        face = getMonoFace(size)
        cell_w = measureCell(face, screen_w, bold)
    else
        local probe = getMonoFace(20)
        local probe_w = measureCell(probe, screen_w, bold)
        size = math.max(4, math.floor(20 * (screen_w / cols) / probe_w))
        face = getMonoFace(size)
        cell_w = measureCell(face, screen_w, bold)
        while cell_w * cols > screen_w and size > 4 do
            size = size - 1
            face = getMonoFace(size)
            cell_w = measureCell(face, screen_w, bold)
        end
    end
    local face_h, ascender = face.ftsize:getHeightAndAscender()
    local cell_h = math.max(1, math.ceil(face_h))
    local rows = math.max(1, math.floor(screen_h / cell_h))

    return {
        screen_w = screen_w, screen_h = screen_h,
        cols = cols, rows = rows,
        face = face, font_size = size, bold = bold, cell_w = cell_w, cell_h = cell_h,
        baseline = math.floor(ascender),
    }
end

-- Fits an img_w×img_h picture into the cols×rows grid of (non-square) cells,
-- keeping its aspect ratio. Returns the number of columns/rows actually used.
local function fitGrid(img_w, img_h, m)
    local box_w, box_h = m.cols * m.cell_w, m.rows * m.cell_h
    local f = math.min(box_w / img_w, box_h / img_h)
    local used_cols = math.max(1, math.floor(img_w * f / m.cell_w))
    local used_rows = math.max(1, math.floor(img_h * f / m.cell_h))
    return used_cols, used_rows
end

-- Centre-crops `bb` to the aspect ratio of the full screen grid. Returns a new
-- BlitBuffer (and frees the original) or the original when no crop is needed.
local function cropToGrid(bb, m)
    local w, h = bb:getWidth(), bb:getHeight()
    local box_ar = (m.cols * m.cell_w) / (m.rows * m.cell_h)
    local cw, ch = w, h
    if w / h > box_ar then
        cw = math.max(1, math.floor(h * box_ar))
    else
        ch = math.max(1, math.floor(w / box_ar))
    end
    if cw == w and ch == h then return bb end
    local cropped = Blitbuffer.new(cw, ch, bb:getType())
    cropped:blitFrom(bb, 0, 0, math.floor((w - cw) / 2), math.floor((h - ch) / 2), cw, ch)
    bb:free()
    return cropped
end

-- Applies the placement mode. Returns the (possibly replaced) cover bb and the
-- grid size to convert to.
--   fit     keep aspect, whole cover visible, margins around it
--   fill    keep aspect, cover the whole grid, overflow cropped
--   stretch ignore aspect, use the whole grid
local function prepareCover(cover_bb, m, mode)
    if mode == "stretch" then
        return cover_bb, m.cols, m.rows
    elseif mode == "fill" then
        return cropToGrid(cover_bb, m), m.cols, m.rows
    end
    local used_cols, used_rows = fitGrid(cover_bb:getWidth(), cover_bb:getHeight(), m)
    return cover_bb, used_cols, used_rows
end

-- ---------------------------------------------------------------------------
-- Engines: BlitBuffer → array of text lines (used_cols × used_rows)
-- ---------------------------------------------------------------------------
local function asciiLocal(cover_bb, cols, rows, charset, gamma)
    local small = RenderImage:scaleBlitBuffer(cover_bb, cols, rows, false)
    local ramp = RAMPS[charset] or RAMPS.simple
    local n = #ramp
    gamma = gamma or 1.0
    local lines = {}
    for y = 0, rows - 1 do
        local row = {}
        for x = 0, cols - 1 do
            local lum = small:getPixel(x, y):getColor8A().a -- 0 (black) .. 255 (white)
            local v = lum / 255
            if gamma ~= 1.0 then v = v ^ gamma end
            local idx = math.floor(v * n) + 1
            if idx > n then idx = n end
            row[x + 1] = ramp[idx]
        end
        lines[y + 1] = table.concat(row)
    end
    if small ~= cover_bb then small:free() end
    return lines
end

local function splitLines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        lines[#lines + 1] = line
    end
    while #lines > 0 and lines[#lines]:match("^%s*$") do
        lines[#lines] = nil
    end
    return lines
end

local function asciiApiLeague(cover_bb, cols, rows)
    local https      = require("ssl.https")
    local ltn12      = require("ltn12")
    local socketutil = require("socketutil")

    util.makePath(CACHE_DIR)
    local tmp = CACHE_DIR .. "/upload.png"

    -- Upload a downscaled copy with the exact aspect of the requested grid
    -- (the API treats cells as square and fits the picture into width×height),
    -- at 4× the grid so it has some detail to work with. Keeps uploads tiny.
    local small = RenderImage:scaleBlitBuffer(cover_bb, cols * 4, rows * 4, false)
    local ok_png, err = pcall(small.writePNG, small, tmp)
    if small ~= cover_bb then small:free() end
    if not ok_png then
        return nil, T(_("Could not encode cover: %1"), tostring(err))
    end
    local body = util.readFromFile(tmp, "rb")
    os.remove(tmp)
    if not body or body == "" then
        return nil, _("Could not read encoded cover.")
    end

    local url = string.format("%s?api-key=%s&width=%d&height=%d", API_URL, getApiKey(), cols, rows)
    local chunks = {}
    socketutil:set_timeout(10, 30)
    local ok_req, code, headers = https.request{
        url     = url,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "image/png",
            ["Content-Length"] = tostring(#body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(chunks),
    }
    socketutil:reset_timeout()
    local text = table.concat(chunks)

    if ok_req ~= 1 then
        return nil, T(_("Network error: %1"), tostring(code))
    end
    if code ~= 200 then
        return nil, T(_("API error %1: %2"), tostring(code), text:sub(1, 200))
    end
    local lines = splitLines(text)
    if #lines == 0 then
        return nil, _("API returned no ASCII art.")
    end
    local quota_left = headers and (headers["x-api-quota-left"] or headers["X-API-Quota-Left"])
    return lines, nil, quota_left
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------
local function cachePath(file, engine, mode, charset, tone, cols, rows)
    local md5 = util.partialMD5(file)
    if not md5 then return nil end
    -- The API picks its own glyphs and tones, so those only matter locally.
    local cs = engine == "apileague" and "api" or (charset .. "-" .. tone)
    return string.format("%s/%s_%s_%s_%s_%dx%d.txt", CACHE_DIR, md5, engine, mode, cs, cols, rows)
end

local function readCache(path)
    if not path or not fileExists(path) then return nil end
    local text = util.readFromFile(path, "r")
    if not text or text == "" then return nil end
    local lines = splitLines(text)
    if #lines == 0 then return nil end
    return lines
end

local function writeCache(path, lines)
    util.makePath(CACHE_DIR)
    util.writeToFile(table.concat(lines, "\n"), path)
end

local function clearCache()
    local n = 0
    if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then return n end
    for entry in lfs.dir(CACHE_DIR) do
        if entry:match("%.txt$") or entry:match("%.png$") then
            if os.remove(CACHE_DIR .. "/" .. entry) then n = n + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Pipeline
-- ---------------------------------------------------------------------------
-- Returns lines, was_cached, err, quota_left.
-- `allow_network` false → the API engine only serves cached results.
local function getAscii(ui, file, engine, m, allow_network)
    if not (ui and ui.bookinfo) then return nil, false, _("No book info available.") end
    local cover_bb = ui.bookinfo:getCoverImage(ui.document, file)
    if not cover_bb then return nil, false, _("No cover image available.") end

    local mode = getFitMode()
    local charset = getCharset()
    local tone = getTone()
    local used_cols, used_rows
    cover_bb, used_cols, used_rows = prepareCover(cover_bb, m, mode)
    local cpath = cachePath(file, engine, mode, charset, tone, used_cols, used_rows)
    local lines = readCache(cpath)
    if lines then
        cover_bb:free()
        return lines, true
    end

    local err, quota_left
    if engine == "apileague" then
        if allow_network then
            lines, err, quota_left = asciiApiLeague(cover_bb, used_cols, used_rows)
        else
            err = "not cached"
        end
    else
        lines = asciiLocal(cover_bb, used_cols, used_rows, charset, TONE_GAMMA[tone])
    end
    cover_bb:free()

    if lines and cpath then
        local ok, werr = pcall(writeCache, cpath, lines)
        if not ok then logger.warn("ascii cover: cache write failed:", werr) end
    end
    return lines, false, err, quota_left
end

-- Number of characters (not bytes) in a UTF-8 string.
local function utf8Len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

local function renderAscii(lines, m)
    local bb = Blitbuffer.new(m.screen_w, m.screen_h, Screen.bb:getType())
    bb:fill(Blitbuffer.COLOR_WHITE)
    local max_len = 0
    for _i, line in ipairs(lines) do
        local len = utf8Len(line)
        if len > max_len then max_len = len end
    end
    local x0 = math.max(0, math.floor((m.screen_w - max_len * m.cell_w) / 2))
    local y0 = math.max(0, math.floor((m.screen_h - #lines * m.cell_h) / 2))
    for i, line in ipairs(lines) do
        if line ~= "" then
            RenderText:renderUtf8Text(bb, x0, y0 + (i - 1) * m.cell_h + m.baseline,
                m.face, line, false, m.bold, Blitbuffer.COLOR_BLACK)
        end
    end
    return bb
end

-- Full-screen BlitBuffer for the sleep screen, or nil.
local function buildSleepImage(ui)
    local file = resolveTargetFile(ui)
    if not file then return nil end
    local engine = getEngine()
    local m = getMetrics()
    local lines = getAscii(ui, file, engine, m, false)
    if not lines and engine ~= "local" then
        -- No cached API result: never hit the network while suspending.
        lines = getAscii(ui, file, "local", m, false)
    end
    if not lines then return nil end
    local max_len = 0
    for _i, line in ipairs(lines) do
        local len = utf8Len(line)
        if len > max_len then max_len = len end
    end
    logger.info(string.format(
        "ascii cover: screen %dx%d, grid %dx%d, cell %dx%d (font %d%s), text %dx%d, mode %s, charset %s, tone %s, engine %s, file %s",
        m.screen_w, m.screen_h, m.cols, m.rows, m.cell_w, m.cell_h, m.font_size, m.bold and " bold" or "",
        max_len, #lines, getFitMode(), getCharset(), getTone(), engine, file))
    return renderAscii(lines, m)
end

-- Converts (and caches) the target book with the configured engine.
-- interactive → shows progress/result messages and may bring WiFi up.
local function convertNow(ui, interactive)
    local InfoMessage = require("ui/widget/infomessage")
    local function report(text, timeout)
        if interactive then
            UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
        else
            logger.info("ascii cover:", text)
        end
    end

    local file = resolveTargetFile(ui)
    if not file then
        report(_("No book found to convert."), 3)
        return
    end
    local engine = getEngine()
    local m = getMetrics()

    local run = function()
        local busy
        if interactive then
            busy = InfoMessage:new{ text = _("Converting cover to ASCII art…") }
            UIManager:show(busy)
            UIManager:forceRePaint()
        end
        local ok, lines, cached, err, quota = pcall(getAscii, ui, file, engine, m, true)
        if busy then UIManager:close(busy) end
        if not ok then
            report(T(_("Conversion failed: %1"), tostring(lines)), 5)
        elseif not lines then
            report(T(_("Conversion failed: %1"), tostring(err)), 5)
        elseif cached then
            report(_("Cover already converted (using cached result)."), 3)
        else
            local msg = T(_("Cover converted: %1 lines."), #lines)
            if quota then
                msg = msg .. "\n" .. T(_("API quota left: %1"), tostring(quota))
            end
            report(msg, 4)
        end
    end

    if engine == "apileague" then
        local NetworkMgr = require("ui/network/manager")
        if interactive then
            NetworkMgr:runWhenOnline(run)
        elseif NetworkMgr:isConnected() then
            run()
        else
            logger.dbg("ascii cover: offline, skipping API conversion")
        end
    else
        run()
    end
end

-- ---------------------------------------------------------------------------
-- Screensaver hooks
-- ---------------------------------------------------------------------------
local function effectiveTypeKey(event)
    local prefix = event and (event .. "_") or ""
    if G_reader_settings:has(prefix .. "screensaver_type") then
        return prefix .. "screensaver_type"
    end
    return "screensaver_type"
end

local orig_setup = Screensaver.setup
Screensaver.setup = function(self, event, event_message)
    local type_key = effectiveTypeKey(event)
    if G_reader_settings:readSetting(type_key) ~= TYPE then
        return orig_setup(self, event, event_message)
    end

    -- Let core set ui/prefix/message state; it leaves our type unresolved.
    orig_setup(self, event, event_message)
    if not self.ui then return end

    local ok, bb = pcall(buildSleepImage, self.ui)
    if not ok then
        logger.warn("ascii cover: build failed:", bb)
        bb = nil
    end
    if bb then
        self.image = bb
        self.image_file = nil
        self.screensaver_type = "cover"
        self.screensaver_background = G_reader_settings:readSetting("screensaver_img_background")
        return
    end

    -- Fallback: core's plain "book cover" mode (with its own random-image fallback).
    local old = G_reader_settings:readSetting(type_key)
    G_reader_settings:saveSetting(type_key, "cover")
    local ok2, err = pcall(orig_setup, self, event, event_message)
    G_reader_settings:saveSetting(type_key, old)
    if not ok2 then error(err) end
end

-- Pre-convert with the API engine when a book is opened and WiFi is already up,
-- so a result is cached by the time the device goes to sleep.
do
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI and not ReaderUI.__ascii_cover_patched then
        ReaderUI.__ascii_cover_patched = true
        local orig_init = ReaderUI.init
        ReaderUI.init = function(self, ...)
            orig_init(self, ...)
            if G_reader_settings:readSetting("screensaver_type") == TYPE and getEngine() == "apileague" then
                UIManager:scheduleIn(5, function()
                    if ReaderUI.instance ~= self or not self.document then return end
                    local ok_c, err = pcall(convertNow, self, false)
                    if not ok_c then logger.warn("ascii cover: auto-convert failed:", err) end
                end)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------
local function genRadio(text, setting, value, help_text)
    -- Upvalues are deliberately named `setting`/`value`: other patches
    -- (dual-state screensaver) read them to discover wallpaper types.
    return {
        text = text,
        help_text = help_text,
        radio = true,
        checked_func = function()
            return G_reader_settings:readSetting(setting) == value
        end,
        callback = function()
            G_reader_settings:saveSetting(setting, value)
        end,
    }
end

local function isSelected()
    return G_reader_settings:readSetting("screensaver_type") == TYPE
end

local function showTextDialog(title, key, hint, description, on_save)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = G_reader_settings:readSetting(key) or "",
        input_hint = hint,
        description = description,
        allow_newline = false,
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local val = dlg:getInputText()
                    if val == "" then
                        G_reader_settings:delSetting(key)
                    else
                        G_reader_settings:saveSetting(key, val)
                    end
                    UIManager:close(dlg)
                    if on_save then on_save() end
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function genSettingsMenu()
    return {
        text = _("ASCII cover settings"),
        enabled_func = isSelected,
        sub_item_table = {
            {
                text_func = function()
                    local n = #getExcludes()
                    if n == 0 then return _("Exclude paths") end
                    return T(_("Exclude paths (%1)"), n)
                end,
                help_text = _("Comma-separated path fragments. If the current (or last opened) book's path contains any of them, the reading history is searched backwards for the most recent book that is not excluded, and its cover is shown instead."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    showTextDialog(_("Exclude paths"), KEY_EXCLUDE,
                        "/mnt/onboard/rss, instapaper",
                        _("Comma-separated path fragments.\nBooks whose path contains any fragment will be skipped."),
                        function() if touchmenu_instance then touchmenu_instance:updateItems() end end)
                end,
                separator = true,
            },
            {
                text_func = function()
                    local cols = getColumns()
                    if isAutoColumns() then
                        return T(_("Quality: auto (%1 columns)"), cols)
                    end
                    for _i, p in ipairs(QUALITY_PRESETS) do
                        if p.cols == cols then
                            return T(_("Quality: %1 (%2 columns)"), p.label, cols)
                        end
                    end
                    return T(_("Quality: custom (%1 columns)"), cols)
                end,
                help_text = _("Characters per line. More columns give finer detail with smaller glyphs."),
                sub_item_table_func = function()
                    local items = {}
                    items[1] = {
                        text_func = function()
                            return T(_("Auto by screen size (%1 columns)"), clampColumns(autoColumns()))
                        end,
                        help_text = _("Keeps the glyph size fixed and derives the column count from the screen width, so larger or denser screens get a finer grid."),
                        radio = true,
                        checked_func = isAutoColumns,
                        callback = function()
                            G_reader_settings:saveSetting(KEY_COLUMNS, "auto")
                        end,
                        separator = true,
                    }
                    for _i, p in ipairs(QUALITY_PRESETS) do
                        items[#items + 1] = {
                            text = T("%1 (%2)", p.label, p.cols),
                            radio = true,
                            checked_func = function() return not isAutoColumns() and getColumns() == p.cols end,
                            callback = function()
                                G_reader_settings:saveSetting(KEY_COLUMNS, p.cols)
                            end,
                        }
                    end
                    items[#items].separator = true
                    items[#items + 1] = {
                        text = _("Custom columns…"),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            UIManager:show(SpinWidget:new{
                                value = getColumns(),
                                value_min = MIN_COLUMNS,
                                value_max = MAX_COLUMNS,
                                value_step = 4,
                                value_hold_step = 20,
                                default_value = DEFAULT_COLUMNS,
                                title_text = _("ASCII art columns"),
                                ok_text = _("Set"),
                                callback = function(spin)
                                    G_reader_settings:saveSetting(KEY_COLUMNS, spin.value)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    }
                    return items
                end,
                separator = true,
            },
            {
                text_func = function()
                    local cs = getCharset()
                    local label = cs == "detailed" and _("detailed")
                               or cs == "blocks" and _("blocks")
                               or _("simple")
                    return T(_("Character set: %1"), label)
                end,
                help_text = _("Glyphs used for the on-device conversion. The API League engine chooses its own glyphs."),
                sub_item_table = {
                    genRadio(_("Simple (12 glyphs)"), KEY_CHARSET, "simple",
                        _("Punctuation ramp: @%#*+=;:-,. and space. Clean, high contrast.")),
                    genRadio(_("Detailed (70 glyphs)"), KEY_CHARSET, "detailed",
                        _("Classic 70-step ramp using letters and symbols. Smoother tones, busier look.")),
                    genRadio(_("Block shading"), KEY_CHARSET, "blocks",
                        _("█ ▓ ▒ ░ and space. Looks like a coarse grayscale picture rather than text. Uses JetBrainsMono-Regular.ttf from the koreader/fonts folder; without it the glyphs come from a fallback font and may misalign.")),
                },
            },
            {
                text = _("Bold glyphs"),
                help_text = _("Thickens the glyph strokes so small characters do not fade into gray on e-ink."),
                checked_func = isBold,
                callback = function()
                    G_reader_settings:flipNilOrTrue(KEY_BOLD)
                end,
            },
            {
                text_func = function()
                    local t = getTone()
                    local label = t == "darker" and _("darker")
                               or t == "darkest" and _("darkest")
                               or _("normal")
                    return T(_("Tone: %1"), label)
                end,
                help_text = _("Shifts mid-tones toward denser glyphs so the picture reads darker. On-device engine only."),
                sub_item_table = {
                    genRadio(_("Normal"), KEY_TONE, "normal"),
                    genRadio(_("Darker"), KEY_TONE, "darker"),
                    genRadio(_("Darkest"), KEY_TONE, "darkest"),
                },
                separator = true,
            },
            {
                text_func = function()
                    local mode = getFitMode()
                    local label = mode == "fill" and _("fill screen")
                               or mode == "stretch" and _("stretch")
                               or _("fit to screen")
                    return T(_("Cover placement: %1"), label)
                end,
                sub_item_table = {
                    genRadio(_("Fit to screen (keep aspect ratio)"), KEY_FIT, "fit",
                        _("The whole cover is visible; empty margins are left where it does not reach the screen edges.")),
                    genRadio(_("Fill screen (keep aspect ratio)"), KEY_FIT, "fill",
                        _("The cover fills the whole screen; the parts that overflow are cropped.")),
                    genRadio(_("Stretch to screen"), KEY_FIT, "stretch",
                        _("The cover fills the whole screen; its aspect ratio is not preserved.")),
                },
                separator = true,
            },
            genRadio(_("Convert on device (offline)"), KEY_ENGINE, "local",
                _("Converts the cover locally. No network, no API key, no quota.")),
            genRadio(_("Convert with API League (online)"), KEY_ENGINE, "apileague",
                _("Uses the apileague.com Image-to-ASCII API. The cover is sent directly in the request; nothing is uploaded elsewhere. Each conversion costs 5 quota points (free tier: 50 per day). Covers are converted when a book is opened while connected, or via 'Convert current cover now', and cached. Without a cached result the on-device engine is used.")),
            {
                text_func = function()
                    local k = G_reader_settings:readSetting(KEY_API_KEY)
                    if type(k) == "string" and k ~= "" then
                        return _("API League key: custom")
                    end
                    return _("API League key: built-in")
                end,
                enabled_func = function() return getEngine() == "apileague" end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    showTextDialog(_("API League key"), KEY_API_KEY, DEFAULT_API_KEY,
                        _("Leave empty to use the built-in key."),
                        function() if touchmenu_instance then touchmenu_instance:updateItems() end end)
                end,
                separator = true,
            },
            {
                text = _("Convert current cover now"),
                help_text = _("Converts the cover that would be shown on the sleep screen right now and stores it in the cache."),
                keep_menu_open = true,
                callback = function()
                    local ui = getActiveUI()
                    local ok, err = pcall(convertNow, ui, true)
                    if not ok then
                        logger.warn("ascii cover: convert failed:", err)
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = T(_("Conversion failed: %1"), tostring(err)), timeout = 5 })
                    end
                end,
            },
            {
                text = _("Clear ASCII cache"),
                keep_menu_open = true,
                callback = function()
                    local n = clearCache()
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = T(_("Removed %1 cached conversions."), n), timeout = 3 })
                end,
            },
        },
    }
end

local function patchScreensaverMenu(menu)
    local wallpaper = type(menu) == "table" and menu[1] and menu[1].sub_item_table
    if type(wallpaper) ~= "table" then return end
    for _i, item in ipairs(wallpaper) do
        if item.__ascii_cover then return end -- already patched
    end
    local radio = genRadio(_("Show ASCII art of book cover on sleep screen"), "screensaver_type", TYPE,
        _("Renders the cover of the current (or last opened) book as ASCII art."))
    radio.__ascii_cover = true
    local settings = genSettingsMenu()
    settings.__ascii_cover = true
    -- Right after core's "Show book cover on sleep screen" entry.
    table.insert(wallpaper, 2, radio)
    table.insert(wallpaper, 3, settings)
end

local orig_dofile = _G.dofile
_G.dofile = function(filepath)
    local res = orig_dofile(filepath)
    if type(filepath) == "string" and filepath:match("screensaver_menu%.lua$") then
        local ok, err = pcall(patchScreensaverMenu, res)
        if not ok then logger.warn("ascii cover: menu patch failed:", err) end
    end
    return res
end

logger.info("ascii cover screensaver patch loaded")
