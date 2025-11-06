# KOReader User Patches

## 2-book-receipt-shortcut-and-lockscreen.lua
Displays reading progress in a visual "receipt" format showing book/chapter progress, estimated time remaining, and book cover.

**Features:**
- Can be triggered via shortcut ( "Book receipt" under "Reader")
- Can be set as screensaver/sleep screen
- When added as wallpaper, it provides background color options (white/black/transparent/random image)
- Selecting the random image option searches for a `book_receipt_background` folder under the `koreader` folder and randomly picks one of its images as the background; if the folder is missing, the background defaults to transparent

**Original code:** Created by Reddit user [hundredpercentcocoa](https://www.reddit.com/user/hundredpercentcocoa/)

**Modifications in this fork:**
- Added wallpaper/screensaver integration with background color options
- Added book cover display in the receipt

---

## 2-exclude-books-from-wallpaper-cover-mode.lua
Lists specific books or directories whose covers should be replaced with random images when KOReader's wallpaper cover mode is active, optionally drawing exclusions from `wallpaper-cover-exclude.txt`.

---

## 2-sleep-overlay.lua
Adds two sleep screen styles:
- **Overlay mode** covers the full screen with a randomly chosen PNG from `sleepoverlays` (samples: https://imgur.com/a/VdqtgvM).
- **Sticker mode** picks PNG stickers from `sleepoverlay_stickers` for playful layouts. Sticker mode supports `corners` (stickers in each corner) and `random` (1–6 stickers placed randomly) and can be tuned with simple parameters such as maximum sticker size, minimum spacing, and how many stickers to draw.
