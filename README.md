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

## 2-gesture-manager-top-bottom-edge-vertical-swipes.lua
Adds two new configurable Gesture Manager entries for one-finger vertical edge swipes:
- `Top edge down`
- `Bottom edge up`

---

## 2-recursive-file-counts.lua
Shows the folder's direct file count and, when different, the total number of files contained in all nested subdirectories in KOReader's file list.

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

## Credits
These patches were created with assistance from Windurf (AI).
