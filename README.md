# <img src='assets/icon.png' width='35' align='center' alt='icon'> MenuBarPicker

A native macOS menu-bar search tool.  Type to fuzzy-filter every menu
item of the frontmost application, then press Enter to click it.

<span>
  <img src='assets/finder.png' width='33%' alt='finder'>
  <img src='assets/photos.png' width='33%' alt='photos'>
  <img src='assets/music.png' width='33%' alt='music'>
</span>


## Features

- **Standalone Swift executable** — no runtime dependencies, no Xcode project
- **Live fuzzy filtering** with scored ranking (word-initial + subsequence)
- **Keyboard navigation** — Up / Down / Enter / Escape
- **Automatic PID resolution** — skips Shortcuts / BackgroundShortcutRunner
- **Accessibility prompting** — detects missing TCC permission and opens System Settings
- **Focus restoration** — reactivates the target app and re-enumerates the menu bar before clicking
- **Apple Shortcuts compatible** — works as a single "Run Shell Script" action


## Quick start

```bash
# Build (requires Xcode command-line tools)
./build.sh

# Run
./MenuBarPicker            # auto-detect frontmost app
./MenuBarPicker -pid 1234  # target a specific PID
./MenuBarPicker -v         # verbose: show PID resolution timing
./MenuBarPicker --benchmark # benchmark all PID resolution strategies
```


## Build from source

The picker is a single-file Swift executable with no external packages:

```bash
swiftc -O -o MenuBarPicker scripts/MenuBarPicker.swift \
  -framework Cocoa -framework ApplicationServices
```

Or use the included build script:

```bash
./build.sh
```


## Accessibility / TCC setup

MenuBarPicker uses the macOS Accessibility API to read and click menu items.
The first time you run it, macOS will prompt you to grant permission.

1. **System Settings → Privacy & Security → Accessibility**
2. Add the `MenuBarPicker` binary (and Terminal / Shortcuts if you launch from there)
3. If the prompt doesn't appear, the binary prints a clear error to stderr

If you move or rebuild the binary, you may need to remove and re-add it.


## Apple Shortcuts integration

1. Create a new Shortcut
2. Add **Run Shell Script** (Shell: `/bin/bash`, Input: none)
3. Paste:
   ```bash
   /path/to/MenuBarPicker
   ```
4. Assign a keyboard shortcut to the Shortcut

The picker handles everything: PID detection, menu enumeration, UI, focus
restoration, and clicking.


## Project layout

```
MenuBarPicker              ← compiled binary (after build)
build.sh                   ← build script
scripts/
  MenuBarPicker.swift      ← standalone picker source (single file)
assets/                    ← screenshots and icons
```


## Credits

Based on the concept from [BenziAhamed/Menu-Bar-Search](https://github.com/BenziAhamed/Menu-Bar-Search),
originally an Alfred Workflow by Benzi Ahamed (Copyright © 2017), itself
inspired by ctwise's ObjC
[Menu Bar Search](https://www.alfredforum.com/topic/1993-menu-search/).

MenuBarPicker is a standalone rewrite using native AppKit — the fuzzy
search, picker UI, PID resolution, and Shortcuts integration are original
code.  The Accessibility menu-enumeration technique (walking AXMenuBar →
AXMenuItem) is a standard macOS API pattern.

The upstream repository does not include a license file.  This derivative
work does not claim any license over upstream-originated code.  The files
in this repository that are original work are available under the terms
of the [MIT License](https://opensource.org/licenses/MIT).
