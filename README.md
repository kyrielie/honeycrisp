# Honeycrisp Reader
<img width="1024" height="1024" alt="honeycrispicon" src="https://github.com/user-attachments/assets/acacb149-273b-4ade-92b4-69538ee41796" />

A native macOS EPUB reader built with AppKit + WebKit, inspired by this [EPUBQuickLook plugin](https://github.com/arytek/epub-quicklook-extension).

Built using claude and gemini because I hate swift.

Download release to try, might have to bypass macos gatekeeper because I didn't sign it.
```xattr -d com.apple.quarantine /path/to/app```

## Features

- **Persistent windows** — stays open, unlike Quick Look
- ~~**Multiple windows** — open several books simultaneously (File > Open, or ⌘O)~~ broken
- ~~**Paginated mode** — one spine document per "page"~~ broken, navigate with ← → arrow keys jumps one window height though
- **Scroll mode** — all chapters merged into one continuous scroll
- **Float on top** — pin any window above all others (⌘⇧T or toolbar pin button)
- **Reading history** — recent books saved with open date, accessible via clock toolbar button
- ~~**Opinionated typography** — Lora serif + warm parchment palette;~~ Dark, light and sepia only. All EPUB styling is ignored for a consistent reading experience
- **Dark mode** — automatic, follows system appearance

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| ← / → | Previous / next page (paginated mode) |
| ↑ / ↓ | Scroll up/down (scroll mode) |
| Page Up / Page Down | Previous / next page or large scroll |
| ⌘O | Open EPUB file |
| ⌘W | Close window |
| ⌘⇧T | Toggle float on top |

## Building

### Xcode (recommended)

1. Open `Honeycrisp.xcodeproj` in Xcode 15+
2. Xcode will automatically resolve the ZIPFoundation Swift Package dependency
3. Select the **Honeycrisp** scheme → **My Mac** destination
4. Press ⌘R to build and run

> **Note:** Set your own Team in Signing & Capabilities if you see code signing errors.

### Requirements

- macOS 13.0+ (Ventura or later)
- Xcode 15+
- ZIPFoundation (fetched automatically via Swift Package Manager)

## Architecture

| File | Responsibility |
|------|---------------|
| `EPUBReaderApp.swift` | SwiftUI `@main` entry point, boots `AppDelegate` |
| `AppDelegate.swift` | Application lifecycle, menu bar, window creation |
| `ReaderWindowController.swift` | Per-window chrome, float-on-top, toolbar scaffold |
| `ReaderViewController.swift` | WebKit rendering, pagination, keyboard nav, toolbar items |
| `EPUBParser.swift` | ZIP extraction, OPF/spine parsing, HTML generation |
| `HistoryManager.swift` | Persists recently opened files with security-scoped bookmarks |
| `HistoryViewController.swift` | Popover showing recent books with open/remove actions |

The QuickLook plugin (`EPUBQuickLook`) provided the `EPUBParser` core and the basic WebKit rendering approach. (I think, I just told claude to use it.)

- Full `NSWindowController` lifecycle with multiple independent windows
- Paginated reading mode driven by the spine order
- Arrow key navigation with `ReaderWindow` key forwarding
- Window-level floating (`.floating` NSWindow level)
- Persistent history via `UserDefaults` + security-scoped bookmarks
- Toolbar with mode switcher, page indicator, history popover, pin button
- Opinionated reader CSS that strips all EPUB styles (Lora typeface, warm paper palette)

## License

MIT
