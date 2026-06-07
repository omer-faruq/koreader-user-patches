# KOReader User Patches

## How to use these patches
- Create the `patches` folder in the `koreader` directory if it doesn't exist.
- Place the related `.lua` file in the `patches` folder in the `koreader` directory.
- Follow other steps(like creating another folder, editing the lua file, etc.) if mentioned.
- Restart KOReader.

## 2-book-receipt-shortcut-and-lockscreen.lua
Displays reading progress in a visual "receipt" format showing book/chapter progress, estimated time remaining, and book cover.

**Features:**
- Can be triggered via shortcut ( "Book receipt" under "Reader")
- Can be set as screensaver/sleep screen
- Offers selectable content modes: Book receipt, Highlight + progress, or Random (alternates between the two)
- When added as wallpaper, it provides background color options (white/black/transparent/random image/book cover)
- Selecting the `random image` option searches for a `book_receipt_background` folder under the `koreader` folder and randomly picks one of its images as the background; if the folder is missing, the background defaults to transparent (some examples: https://imgur.com/a/zzfbl0J )
- Selecting the `book cover` option uses the current book's cover art as the background
- Displays the configured sleep screen message when available

**Original code:** Created by Reddit user [hundredpercentcocoa](https://www.reddit.com/user/hundredpercentcocoa/)

**Modifications in this fork:**
- Added wallpaper/screensaver integration with background color options
- Added book cover display in the receipt
- Added content modes including highlight/progress view and random rotation between modes

---

## 2-coverbrowser-list-stretched.lua
Stretches book covers in CoverBrowser list mode to a uniform 2:3 portrait aspect ratio, eliminating layout shifts. Also fixes visual corruption in SimpleUI's folder covers feature during navigation.

**Features:**
- **Uniform cover dimensions**: All covers are stretched to a consistent 2:3 (width/height) portrait slot, regardless of original aspect ratio
- **Fixes SimpleUI folder cover corruption**: Prevents memory corruption that caused visual artifacts when navigating back to cached folder covers (folder covers are a SimpleUI-specific feature, not part of default CoverBrowser)
- **No configuration needed**: Automatically patches both CoverBrowser and SimpleUI plugins when loaded

**Requirements:**
- KOReader's CoverBrowser plugin must be enabled
- For folder cover fixes: SimpleUI plugin must also be enabled

**Reference:** `2-CoverBrowserMosaicStretched.lua.txt` (based on KOReader PR #11838: https://github.com/koreader/koreader/pull/11838).

---

## 2-dual-state-screensaver-mode.lua
Adds a new screensaver type, **Dual-state screensaver mode**, which lets you use different screensavers depending on where you are:
- **Book list mode** (File Manager / library)
- **Book mode** (Reader)

You can configure each state to use either:
- A dedicated random-image folder (`book_list_screensavers` / `book_mode_screensavers`)
- Any of KOReader's existing wallpaper/screensaver types (e.g., `cover`, `random_image`, etc.)

**Setup (optional):**
- To use Book list screensavers, create `book_list_screensavers` under the `koreader` folder and put images inside it.
- To use Book mode screensavers, create `book_mode_screensavers` under the `koreader` folder and put images inside it.

**Where to configure:**
- Open KOReader settings for wallpaper/screensaver type.
- Select `Dual-state screensaver mode`.
- Go into `Dual state settings` to configure both states and their image placement (`center`, `fit`, `stretch`) when using the dedicated folders.

---

## 2-exclude-books-from-wallpaper-cover-mode.lua
Lists specific books or directories whose covers should be replaced with random images when KOReader's wallpaper cover mode is active, optionally drawing exclusions from `wallpaper-cover-exclude.txt`.

---

## 2-fallbackcover.lua
Displays a chosen image as the cover for any book that has no embedded cover art, in both mosaic and list CoverBrowser modes. Optionally overlays the book title and author on the image.

**Setup:**
1. Copy `2-fallbackcover.lua` into the `koreader/patches/` folder.
2. Place your fallback image in the same folder, named one of: `fallbackcover.jpg`, `fallbackcover.png`, `fallbackcover.bmp`, `fallbackcover.gif`, `fallbackcover.webp`.

No editing required. Alternatively, open the file and set `FALLBACK_IMAGE_PATH` to an absolute path pointing to any image anywhere on the device.

**Configuration (top of the file):**
- `FALLBACK_IMAGE_PATH` — leave as `nil` for auto-detect, or set an absolute path to any image.
- `FALLBACK_IMAGE_FOLDER` — set to a folder path to pick a random image per book instead of a single file (e.g., "/mnt/onboard/fallback_covers"). Each book gets a consistent random image across sessions. **This overrides `FALLBACK_IMAGE_PATH` when set.**
- `SHOW_TITLE` — set to `true` to overlay the book title on the fallback cover, `false` to disable.
- `SHOW_AUTHOR` — set to `true` to also show the author below the title (only used when `SHOW_TITLE` is `true`).
- `TITLE_FONT` / `AUTHOR_FONT` — if you want to use a font that has more than one ttf file (for bold, italic, regular, etc), make the font name match the name of the specific one you want to use, minus the file extension (ex: "Lexend-Regular").
- `TITLE_COLOR` / `AUTHOR_COLOR` — text color, either "black" or "white".
- `TITLE_BOLD` / `AUTHOR_BOLD` — set to `true` for bold text, `false` for regular weight.
- `TITLE_MIN_SIZE` / `TITLE_MAX_SIZE` — minimum and maximum font sizes in pixels for title text (scales with cover height).
- `APPLY_ONLY_TO` — comma-separated list of path prefixes to restrict fallback covers to specific folders (e.g., "/mnt/onboard/books,/mnt/onboard/My Documents"). Leave empty to apply to all books.
- `EXCLUDE_PATHS` — comma-separated list of path substrings to exclude from fallback covers (e.g., "/mnt/onboard/RSS,instapaper,cache").

The title and author text is word-wrapped (up to 3 lines for title, 1 line for author), centered horizontally and vertically on the image, rendered in black or white directly on the image without any background. Font size scales with cover height.

**Requirements:**
- KOReader's CoverBrowser plugin must be enabled.
- Only books that have been fully indexed (cover extraction attempted) but found to have no cover will show the fallback. Books not yet scanned will be indexed normally first.
- If you later assign a real cover to a book via KOReader, it will immediately take precedence over the fallback.

---

## 2-gesture-manager-top-bottom-edge-vertical-swipes.lua
Adds two new configurable Gesture Manager entries for one-finger vertical edge swipes:
- `Top edge down`
- `Bottom edge up`

---

## 2-menu-tap-swipe-zone-heights.lua
Lets you fine-tune the tap/swipe trigger zone heights for opening KOReader menus:
- **Top menu** (Reader + File Manager) tap/swipe zones
- **Bottom config menu** (Reader) tap/swipe zones

**Heights (pixels):**
- `0` disables that gesture entirely.
- `-1` keeps KOReader's default height (≈ 1/8 of screen height).
- `>0` sets an explicit pixel height. Ratio is derived from your screen height at runtime.

**How to set:**
- Open the file and set `TOP_MENU_TAP_HEIGHT_PX`, `TOP_MENU_SWIPE_HEIGHT_PX`, `BOTTOM_MENU_TAP_HEIGHT_PX`, `BOTTOM_MENU_SWIPE_HEIGHT_PX`.
- Restart KOReader.

---

## 2-precise-line-word-navigation.lua
Enables precise line-by-line and word-by-word cursor movement for highlight selection on non-touch devices (e.g., Kindle 4).

**Features:**
- **Up/Down arrows** move the highlight indicator exactly one line at a time
- **Left/Right arrows** jump from word to word
- Prevents multi-line or multi-word skipping during navigation
- Uses intelligent text detection to align cursor with actual text positions
- Caches line height for consistent vertical movement
- Automatically handles page boundaries and status bar areas

**How it works:**
- Overrides the default highlight indicator movement behavior
- Samples multiple positions to calculate consistent line heights
- Searches for text on target lines to ensure accurate positioning
- Maintains cursor alignment with word boundaries during horizontal navigation

---

## 2-random-book-cover-screensaver.lua
Adds a new screensaver type, **Show random book cover on sleep screen**, that dynamically picks what to display:
- In **Reader**: shows the current book cover.
- In **File Manager**: picks a random book under the current folder (skipping dot-directories) and shows its cover.

If no suitable book/cover is found, it falls back to KOReader's existing screensaver behavior (e.g., `random_image` when a folder is configured, or the configured custom image).

**Where to configure:**
- Open KOReader settings for wallpaper/screensaver type.
- Select `Show random book cover on sleep screen`.
- Configure `Random book cover mode` (`Fit`, `Stretch`, `Center`).

---

## 2-reading-stats-current-book-days-percent.lua
Enhances the per-day entries in **Statistics** for the current book by appending the daily pages read as a percentage of the book's total pages. ( ie, this page: Tools > Reading Statistics > Current Book > Days reading this book)

Example output format:
- `HH:MM (X pages), Y.YY%`

The total page count is inferred from the statistics database when available.

---

## 2-recursive-file-counts.lua
Shows the folder's direct file count and, when different, the total number of files contained in all nested subdirectories in KOReader's file list.

**Parameter:**
- `SHOW_DIRECT_AND_TOTAL_FILE_COUNTS`: when `true`, shows `direct(total)` if total differs, otherwise shows `direct` only; when `false`, always shows only the total (recursive) file count.

---

## 2-screensaver-always-full-refresh.lua
Forces a full e-ink refresh (white flash + `refreshFull`) right before the screensaver/sleep screen appears, no matter which screensaver type is active, and adds a "Full refresh count" item to the bottom of the sleep screen settings to control how many times this happens.

Stock KOReader only flashes/refreshes the screen first for the `cover` and `random_image` screensaver types. Other types — `message`, `disable` with an overlay, or custom screensavers added by plugins/patches (e.g. book receipt, SimpleUI home screen, sleep overlay) — draw directly on top of whatever was on screen, which can leave ghosting on eInk displays. This patch hooks `Screensaver:setup()` (which always runs immediately before `show()`, for every screensaver type, with no bypass branches) so the full-refresh flash always runs first, regardless of screensaver type.

**Where to configure:**
- Open KOReader settings for wallpaper/screensaver type.
- At the bottom of the menu, tap `Full refresh count before sleep screen` to set how many consecutive refresh passes to perform:
  - `0` — disabled, patch does nothing.
  - `1` — one refresh pass (default).
  - `2`–`5` — that many consecutive passes (more aggressive ghosting removal at the cost of extra time/flashing).

**Requirements:**
- Only does anything on devices with an e-ink screen (`Device:hasEinkScreen()`).

---

## 2-sleep-overlay.lua
Adds two sleep screen styles:
- **Overlay mode** covers the full screen with a randomly chosen PNG from `sleepoverlays` folder (samples: https://imgur.com/a/VdqtgvM).
- **Sticker mode** picks PNG stickers from `sleepoverlay_stickers` folder for playful layouts. Sticker mode supports `corners`, `random`, and `frame`:
  - `corners` drops stickers into the four corners.
  - `random` scatters a configurable number of stickers anywhere on screen.
  - `frame` places stickers inside a border strip, using `sticker_frame_depth` to define the inset from the screen edge.

Sticker parameters:
- `use_stickers` toggles sticker mode.
- `sticker_mode` selects the layout (`corners`, `random`, or `frame`).
- `sticker_max_fraction` limits sticker size relative to screen.
- `sticker_min_distance_fraction` enforces spacing (random/frame).
- `sticker_random_min` / `sticker_random_max` control sticker counts (random/frame).
- `sticker_frame_depth` sets the border thickness used by frame mode.

---

## 2-toc-level-selector.lua
Lets you choose which TOC levels (h1, h2, h3, etc.) to show or hide **per book**. Hidden levels are removed everywhere (TOC viewer, navigation, footer chapter titles, statistics, etc.), not just from progress bar ticks. Depth numbers are compacted so visible levels stay contiguous.

**How to use:**
- Open a book, then the Reader main menu.
- Tap `Select visible TOC levels` to open the picker.
- Toggle any depth to hide/show it; `Reset all to visible` clears hiding.
- Tap `Apply changes` to save per-book settings and rebuild the TOC with the new visibility.

**Notes:**
- Settings persist per book across sessions.
- If you hide all levels, the TOC can be empty by design.

---

## Credits
These patches were created with assistance from Windurf (AI).
