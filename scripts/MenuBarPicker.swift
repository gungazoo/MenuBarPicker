#!/usr/bin/env swift
// MenuBarPicker.swift — Native searchable menu-bar picker for Apple Shortcuts
//
// Standalone Swift executable.  No external dependencies.
//
// Usage:
//   MenuBarPicker            (auto-detect frontmost non-Shortcuts app)
//   MenuBarPicker -pid 1234  (target a specific PID)
//
// Build:
//   swiftc -O -o MenuBarPicker MenuBarPicker.swift \
//     -framework Cocoa -framework ApplicationServices
//
// Apple Shortcut (single action):
//   "Run Shell Script" — Shell: /bin/bash, Input: (none)
//   /path/to/MenuBarPicker
//
// The executable:
//   1. Resolves the frontmost non-Shortcuts app PID
//   2. Enumerates its entire AX menu hierarchy
//   3. Shows a focused floating picker window with live filtering
//   4. Supports Up / Down / Enter / Escape
//   5. Reactivates the original app by PID and clicks the selected item
//
// Requires: System Settings → Privacy & Security → Accessibility
//   permission for this binary (and Terminal/Shortcuts if launched from there).

import Cocoa
import ApplicationServices

// ─── AX helpers ────────────────────────────────────────────────

func axAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var val: CFTypeRef?
    AXUIElementCopyAttributeValue(el, attr as CFString, &val)
    return val
}

// ─── Virtual-key → glyph map (for shortcut display) ───────────

private let vkMap: [Int: String] = [
    0x24: "↩", 0x4c: "⌤", 0x47: "⌧", 0x30: "⇥", 0x31: "␣",
    0x33: "⌫", 0x35: "⎋", 0x39: "⇪", 0x3f: "fn",
    0x7a: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
    0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
    0x65: "F9", 0x6d: "F10", 0x67: "F11", 0x6f: "F12",
    0x69: "F13", 0x6b: "F14", 0x71: "F15", 0x6a: "F16",
    0x40: "F17", 0x4f: "F18", 0x50: "F19", 0x5a: "F20",
    0x73: "↖", 0x74: "⇞", 0x75: "⌦", 0x77: "↘",
    0x79: "⇟", 0x7b: "◀︎", 0x7c: "▶︎", 0x7d: "▼", 0x7e: "▲",
]

func decodeShortcut(cmd: String?, modifiers: Int, virtualKey: Int) -> String {
    var key: String? = cmd
    if let s = key, let first = s.unicodeScalars.first, first.value == 0x7f {
        key = "⌦"
    } else if key == nil, virtualKey > 0 {
        key = vkMap[virtualKey]
    }
    var mods = [String]()
    if modifiers & 0x04 != 0 { mods.append("⌃") }
    if modifiers & 0x02 != 0 { mods.append("⌥") }
    if modifiers & 0x01 != 0 { mods.append("⇧") }
    if modifiers & 0x08 == 0 { mods.append("⌘") }
    if let k = key { return mods.joined() + k }
    return ""
}

// ─── Menu item model ──────────────────────────────────────────

struct PickerMenuItem {
    var label: String        // "File > Save As…"
    var shortcut: String     // "⇧⌘S"
    var pathIndices: [Int]   // [2, 5]  – indices into AX children at each level
    var searchText: String   // lowercased label for filtering

    var displayTitle: String {
        shortcut.isEmpty ? label : "\(label)  [\(shortcut)]"
    }
}

// ─── AX menu enumeration ──────────────────────────────────────

func enumerateMenus(
    element: AXUIElement,
    path: [String] = [],
    indices: [Int] = [],
    depth: Int = 0,
    into items: inout [PickerMenuItem]
) {
    guard depth < 10 else { return }
    guard let children = axAttr(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for i in children.indices {
        let child = children[i]
        guard let enabled = axAttr(child, kAXEnabledAttribute) as? Bool else { continue }
        guard let title = axAttr(child, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
        let name = title.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let subChildren = axAttr(child, kAXChildrenAttribute) as? [AXUIElement] else { continue }
        let menuPath = path + [name]
        let idxPath = indices + [i]
        if subChildren.count == 1, enabled {
            // Submenu — recurse
            enumerateMenus(element: subChildren[0], path: menuPath,
                           indices: idxPath, depth: depth + 1, into: &items)
        } else if enabled {
            // Leaf menu item
            let cmd = axAttr(child, kAXMenuItemCmdCharAttribute) as? String
            var mods = 0, vk = 0
            if let m = axAttr(child, kAXMenuItemCmdModifiersAttribute) {
                CFNumberGetValue((m as! CFNumber), .longType, &mods)
            }
            if let v = axAttr(child, kAXMenuItemCmdVirtualKeyAttribute) {
                CFNumberGetValue((v as! CFNumber), .longType, &vk)
            }
            let sc = decodeShortcut(cmd: cmd, modifiers: mods, virtualKey: vk)
            let label = menuPath.joined(separator: " > ")
            items.append(PickerMenuItem(
                label: label,
                shortcut: sc,
                pathIndices: idxPath,
                searchText: label.lowercased()
            ))
        }
    }
}

func loadMenuItems(pid: pid_t) -> (items: [PickerMenuItem], menuBar: AXUIElement?) {
    let axApp = AXUIElementCreateApplication(pid)
    var mbRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &mbRef)
    guard err == .success, let menuBar = mbRef else { return ([], nil) }
    let mb = menuBar as! AXUIElement
    guard let topItems = axAttr(mb, kAXChildrenAttribute) as? [AXUIElement] else { return ([], mb) }
    var items = [PickerMenuItem]()
    for i in topItems.indices {
        let item = topItems[i]
        guard let name = axAttr(item, kAXTitleAttribute) as? String else { continue }
        if name == "Apple" { continue }  // skip Apple menu
        guard let sub = axAttr(item, kAXChildrenAttribute) as? [AXUIElement], !sub.isEmpty else { continue }
        enumerateMenus(element: sub[0], path: [name], indices: [i],
                       depth: 1, into: &items)
    }
    return (items, mb)
}

// ─── AX click by path indices ─────────────────────────────────

func clickMenuPath(_ menuBar: AXUIElement, indices: [Int]) {
    guard !indices.isEmpty else { return }
    var current = menuBar
    for (level, idx) in indices.enumerated() {
        guard let children = axAttr(current, kAXChildrenAttribute) as? [AXUIElement],
              idx < children.count else { return }
        let child = children[idx]
        if level == indices.count - 1 {
            AXUIElementPerformAction(child, kAXPressAction as CFString)
            return
        }
        // Descend into submenu container
        guard let sub = axAttr(child, kAXChildrenAttribute) as? [AXUIElement],
              !sub.isEmpty else { return }
        current = sub[0]
    }
}

// ─── PID cache (inter-action communication) ──────────────────

/// Fixed cache directory — never use NSTemporaryDirectory() or $TMPDIR
/// because BackgroundShortcutRunner has a different TMPDIR than the
/// interactive shell / Shortcuts editor.
private let kCacheDir = "/tmp/menu-bar-search"
private let kPIDCacheFile = "/tmp/menu-bar-search/_frontapp.txt"

func writePIDCache(pid: pid_t) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: kCacheDir, withIntermediateDirectories: true)
    try? "\(pid)".write(toFile: kPIDCacheFile, atomically: true, encoding: .utf8)
}

func readPIDCache() -> pid_t? {
    guard let contents = try? String(contentsOfFile: kPIDCacheFile, encoding: .utf8) else { return nil }
    // The file may contain "PID\nbundleId\nAppName" (menu_helper.py format)
    // or just "PID" (our format). Take the first line.
    let firstLine = contents.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
    guard let v = Int32(firstLine), v > 0 else { return nil }
    // Only trust if the process is still alive
    guard NSRunningApplication(processIdentifier: v) != nil else { return nil }
    return v
}

// ─── Resolve frontmost non-Shortcuts PID ──────────────────────

private let skipBundles: Set<String> = [
    "com.apple.shortcuts",
    "com.apple.WorkflowKit.BackgroundShortcutRunner",
]

/// Bundle IDs that are never the intended target.
private func isShortcutsOrSelf(_ bid: String?, myPID: pid_t, appPID: pid_t) -> Bool {
    if appPID == myPID { return true }
    guard let bid = bid else { return false }
    return skipBundles.contains(bid)
        || bid.contains("BackgroundShortcutRunner")
        || bid.contains("WorkflowKit")
}

/// Legacy check (for functions that don't have myPID handy).
private func isShortcutsBundle(_ bid: String?) -> Bool {
    guard let bid = bid else { return false }
    return skipBundles.contains(bid)
        || bid.contains("BackgroundShortcutRunner")
        || bid.contains("WorkflowKit")
}

// ─── Resolution timing helper ─────────────────────────────────

private var benchmarkMode = false

private func elapsed(from start: UInt64) -> Double {
    let end = DispatchTime.now().uptimeNanoseconds
    return Double(end - start) / 1_000_000.0  // milliseconds
}

// ─── Strategy 1 (fastest): CGWindowList ────────────────────────
//
// Queries the WindowServer directly for the topmost on-screen window's
// owning PID.  Cost: ~0.1–0.5 ms (kernel syscall, no IPC).
// This is the single fastest way to find who owns the top window.

func resolveViaCGWindowList() -> pid_t? {
    let myPID = ProcessInfo.processInfo.processIdentifier
    // Get on-screen windows in front-to-back order
    guard let winList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[CFString: Any]] else { return nil }

    for win in winList {
        guard let layer = win[kCGWindowLayer] as? Int, layer == 0 else { continue }
        guard let ownerPID = win[kCGWindowOwnerPID] as? Int32 else { continue }
        guard ownerPID != myPID else { continue }
        // Validate the PID is a regular GUI app we should target
        guard let app = NSRunningApplication(processIdentifier: ownerPID) else { continue }
        guard app.activationPolicy == .regular else { continue }
        guard !isShortcutsOrSelf(app.bundleIdentifier, myPID: myPID, appPID: ownerPID) else { continue }
        if benchmarkMode {
            fputs("  PID via CGWindowList: \(ownerPID) (\(app.localizedName ?? "?"))\n", stderr)
        }
        return ownerPID
    }
    return nil
}

// ─── Strategy 2: NSWorkspace (fast, ~0.01–0.1 ms) ─────────────

func resolveViaWorkspace() -> pid_t? {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let ws = NSWorkspace.shared
    // menuBarOwningApplication is the most semantically correct target
    if let mbo = ws.menuBarOwningApplication,
       !isShortcutsOrSelf(mbo.bundleIdentifier, myPID: myPID, appPID: mbo.processIdentifier) {
        if benchmarkMode { fputs("  PID via menuBarOwningApplication: \(mbo.processIdentifier)\n", stderr) }
        return mbo.processIdentifier
    }
    if let front = ws.frontmostApplication,
       !isShortcutsOrSelf(front.bundleIdentifier, myPID: myPID, appPID: front.processIdentifier) {
        if benchmarkMode { fputs("  PID via frontmostApplication: \(front.processIdentifier)\n", stderr) }
        return front.processIdentifier
    }
    // Walk all regular apps — prefer those marked active/menuBar-owning
    for app in ws.runningApplications {
        guard app.activationPolicy == .regular else { continue }
        guard app.isActive || app.ownsMenuBar else { continue }
        guard !app.isTerminated else { continue }
        guard !isShortcutsOrSelf(app.bundleIdentifier, myPID: myPID, appPID: app.processIdentifier) else { continue }
        if benchmarkMode { fputs("  PID via runningApplications (active/menuBar): \(app.processIdentifier)\n", stderr) }
        return app.processIdentifier
    }
    return nil
}

// ─── Strategy 3: PID cache (fast, ~0.1 ms file read) ──────────

func resolveViaCachedPID() -> pid_t? {
    guard let pid = readPIDCache() else { return nil }
    // Validate it has a menu bar (avoid stale cache pointing to wrong app)
    let axApp = AXUIElementCreateApplication(pid)
    var mbRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &mbRef)
    guard err == .success else { return nil }
    if benchmarkMode { fputs("  PID via cache: \(pid)\n", stderr) }
    return pid
}

// ─── Strategy 4: Fallback — first visible regular app ──────────

func resolveViaFallback() -> pid_t? {
    let myPID = ProcessInfo.processInfo.processIdentifier
    for app in NSWorkspace.shared.runningApplications {
        guard app.activationPolicy == .regular else { continue }
        guard !app.isTerminated else { continue }
        guard !isShortcutsOrSelf(app.bundleIdentifier, myPID: myPID, appPID: app.processIdentifier) else { continue }
        if benchmarkMode { fputs("  PID via fallback: \(app.processIdentifier)\n", stderr) }
        return app.processIdentifier
    }
    return nil
}

// ─── Strategy 5 (bounded): System Events via osascript ─────────
//
// Only used as a last resort.  Bounded to 2 seconds.
// System Events talks to the window server via Apple Events,
// which is reliable but costs 265–1800 ms.

func resolveViaSystemEvents() -> pid_t? {
    let script = """
    tell application "System Events"
      set allProcs to every process whose visible is true
      repeat with p in allProcs
        set bid to bundle identifier of p
        if bid is not "com.apple.shortcuts" and \
           bid does not contain "BackgroundShortcutRunner" and \
           bid does not contain "WorkflowKit" then
          if frontmost of p is true then
            return unix id of p as text
          end if
        end if
      end repeat
      repeat with p in allProcs
        set bid to bundle identifier of p
        if bid is not "com.apple.shortcuts" and \
           bid does not contain "BackgroundShortcutRunner" and \
           bid does not contain "WorkflowKit" then
          return unix id of p as text
        end if
      end repeat
      return ""
    end tell
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        // Bounded wait: 2 seconds max
        let deadline = DispatchTime.now() + .seconds(2)
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global().async {
            proc.waitUntilExit()
            waitGroup.leave()
        }
        if waitGroup.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            fputs("  System Events timed out (>2s)\n", stderr)
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let v = Int32(s), v > 0 {
            if benchmarkMode { fputs("  PID via System Events: \(v)\n", stderr) }
            return v
        }
    } catch {}
    return nil
}

// ─── Combined resolution — layered fast-to-slow ───────────────

/// Resolution result with diagnostics.
struct PIDResolution {
    let pid: pid_t
    let strategy: String
    let elapsedMs: Double
}

func resolveFrontmostPID() -> PIDResolution? {
    let overallStart = DispatchTime.now().uptimeNanoseconds

    struct Strategy {
        let name: String
        let resolve: () -> pid_t?
    }

    let strategies: [Strategy] = [
        Strategy(name: "NSWorkspace")       { resolveViaWorkspace() },
        Strategy(name: "CGWindowList")      { resolveViaCGWindowList() },
        Strategy(name: "PID cache")         { resolveViaCachedPID() },
        Strategy(name: "Fallback")          { resolveViaFallback() },
        Strategy(name: "System Events")     { resolveViaSystemEvents() },
    ]

    for strat in strategies {
        let t0 = DispatchTime.now().uptimeNanoseconds
        if let pid = strat.resolve() {
            let ms = elapsed(from: t0)
            let totalMs = elapsed(from: overallStart)
            fputs("PID resolved: \(pid) via \(strat.name) (\(String(format: "%.1f", ms)) ms, total \(String(format: "%.1f", totalMs)) ms)\n", stderr)
            return PIDResolution(pid: pid, strategy: strat.name, elapsedMs: totalMs)
        } else if benchmarkMode {
            let ms = elapsed(from: t0)
            fputs("  \(strat.name): miss (\(String(format: "%.1f", ms)) ms)\n", stderr)
        }
    }
    return nil
}

// ─── Benchmark mode: run all strategies and compare ───────────

func runBenchmark() {
    let myPID = ProcessInfo.processInfo.processIdentifier
    fputs("═══ PID Resolution Benchmark ═══\n", stderr)
    fputs("My PID: \(myPID)\n\n", stderr)

    struct BenchResult {
        let name: String
        let pid: pid_t?
        let ms: Double
    }

    let strategies: [(String, () -> pid_t?)] = [
        ("CGWindowList",      resolveViaCGWindowList),
        ("NSWorkspace",       resolveViaWorkspace),
        ("PID cache",         resolveViaCachedPID),
        ("Fallback",          resolveViaFallback),
        ("System Events",     resolveViaSystemEvents),
    ]

    var results: [BenchResult] = []
    for (name, fn) in strategies {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let pid = fn()
        let ms = elapsed(from: t0)
        results.append(BenchResult(name: name, pid: pid, ms: ms))
    }

    fputs("Strategy              Time       Result\n", stderr)
    fputs(String(repeating: "─", count: 56) + "\n", stderr)
    for r in results {
        let pidStr: String
        if let p = r.pid {
            let app = NSRunningApplication(processIdentifier: p)
            pidStr = "\(p) (\(app?.localizedName ?? "?"))"
        } else {
            pidStr = "—"
        }
        let namePad = r.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        let timeStr = String(format: "%6.1f ms", r.ms)
        fputs("\(namePad)  \(timeStr)  \(pidStr)\n", stderr)
    }
    fputs("\n", stderr)

    // Show agreement
    let pids = Set(results.compactMap { $0.pid })
    if pids.count == 1 {
        fputs("✓ All strategies agree: PID \(pids.first!)\n", stderr)
    } else if pids.count > 1 {
        fputs("⚠ Strategies disagree on PID: \(pids.sorted())\n", stderr)
    }
}

// ─── Fuzzy match ──────────────────────────────────────────────
//
// Original implementation.  Two-phase scoring:
//
//   Phase 1 — Word-initial prefix:  collect the first character of
//   each whitespace-delimited word in `text`.  If the query is a
//   prefix of that initials string, return a high score (shorter
//   initials → higher score).
//
//   Phase 2 — Scored subsequence:  greedily match query characters
//   left-to-right through `text`.  Track the longest contiguous run
//   of matched characters, count skipped non-space characters before
//   the first match (leading junk) and between matched characters
//   (interior gaps), and compute a weighted score that rewards long
//   runs and penalizes dispersion.
//
// The scoring constants are tuned for menu-item labels (typically
// 20-60 characters) and are not derived from any external project.

func fuzzyMatch(_ text: String, query: String) -> (matched: Bool, score: Int) {
    guard !query.isEmpty else { return (true, 0) }
    let tLen = text.count
    if query.count > tLen { return (false, 0) }

    // Phase 1: word-initial prefix match
    var initials = [Character]()
    var prevWasSpace = true
    for ch in text {
        let isSpace = ch.isWhitespace
        if prevWasSpace && !isSpace { initials.append(ch) }
        prevWasSpace = isSpace
    }
    if initials.count >= query.count {
        let initialsStr = String(initials)
        if initialsStr.hasPrefix(query) {
            // Tighter match (fewer extra initials) scores higher.
            return (true, 10_000 - (initials.count - query.count) * 3)
        }
    }

    // Phase 2: scored subsequence match
    var qi = query.startIndex
    let qEnd = query.endIndex
    var leadingSkips = 0        // non-space chars before the first match
    var gapChars = 0            // non-space chars between matched chars
    var contig = 0              // current contiguous-match run length
    var bestContig = 0          // longest contiguous-match run
    var matchCount = 0
    var prevMatchPos = -1

    for (pos, ch) in text.enumerated() {
        guard qi < qEnd else { break }
        if ch == query[qi] {
            matchCount += 1
            if prevMatchPos >= 0 && pos == prevMatchPos + 1 {
                contig += 1
            } else {
                contig = 1
            }
            bestContig = max(bestContig, contig)
            prevMatchPos = pos
            qi = query.index(after: qi)
        } else if !ch.isWhitespace {
            if matchCount == 0 { leadingSkips += 1 }
            else { gapChars += 1 }
        }
    }

    guard qi == qEnd else { return (false, 0) }

    // Score: reward contiguous runs, penalize leading junk and gaps,
    // give a small bonus for matching near the end of text (short tail).
    let trailingChars = tLen - (prevMatchPos + 1)
    let score = bestContig * 120
                - leadingSkips * 8
                - gapChars * 2
                - trailingChars
    return (true, score)
}

// ─── Keyable window (guarantees key/main for floating panels) ─

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// ─── AppKit picker window ─────────────────────────────────────

class PickerWindowController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    let searchField: NSTextField
    let tableView: NSTableView
    let scrollView: NSScrollView

    var allItems: [PickerMenuItem] = []
    var filtered: [PickerMenuItem] = []
    var selectedItem: PickerMenuItem?
    var cancelled = false

    override init() {
        // Window
        let w: CGFloat = 620, h: CGFloat = 420
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - w / 2, y: screen.midY - h / 2 + 100)
        window = KeyableWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Menu Bar Search"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = NSColor.windowBackgroundColor

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.contentView = contentView

        // Search field
        searchField = NSTextField(frame: NSRect(x: 16, y: h - 52, width: w - 32, height: 28))
        searchField.placeholderString = "Type to filter menus…"
        searchField.font = NSFont.systemFont(ofSize: 15)
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel
        contentView.addSubview(searchField)

        // Table view
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("menu"))
        col.width = w - 40

        tableView = NSTableView(frame: .zero)
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none

        scrollView = NSScrollView(frame: NSRect(x: 16, y: 8, width: w - 32, height: h - 68))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        contentView.addSubview(scrollView)

        super.init()

        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
    }

    func run(items: [PickerMenuItem]) -> PickerMenuItem? {
        allItems = items
        filtered = items
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        // ── Robust activation sequence ──────────────────────────
        // 1. Show the window first so the system has something to focus
        window.makeKeyAndOrderFront(nil)
        // 2. Force our process to the front (suppress deprecation —
        //    the macOS 14+ parameterless .activate() is advisory and
        //    unreliable for non-foreground processes like Shortcuts children)
        NSApp.activate(ignoringOtherApps: true)
        // 3. Set first responder now
        window.makeFirstResponder(searchField)
        // 4. Deferred re-assertion: macOS may deliver the activation
        //    event asynchronously; re-assert after the run-loop turns.
        DispatchQueue.main.async { [self] in
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeFirstResponder(self.searchField)
        }

        // Install local event monitor for key-down
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleKeyDown(event) ?? event
        }

        NSApp.runModal(for: window)

        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        window.orderOut(nil)

        return cancelled ? nil : selectedItem
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // Escape
            cancelled = true
            NSApp.stopModal()
            return nil

        case 36, 76: // Return / Enter
            let row = tableView.selectedRow
            if row >= 0, row < filtered.count {
                selectedItem = filtered[row]
            }
            NSApp.stopModal()
            return nil

        case 125: // Down arrow
            let next = min(tableView.selectedRow + 1, filtered.count - 1)
            if next >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                tableView.scrollRowToVisible(next)
            }
            return nil

        case 126: // Up arrow
            let prev = max(tableView.selectedRow - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tableView.scrollRowToVisible(prev)
            return nil

        default:
            return event
        }
    }

    // MARK: - NSTextFieldDelegate (live filtering)

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if query.isEmpty {
            filtered = allItems
        } else {
            filtered = allItems
                .compactMap { item -> (PickerMenuItem, Int)? in
                    let (ok, score) = fuzzyMatch(item.searchText, query: query)
                    return ok ? (item, score) : nil
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("MenuCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? 580, height: 26))
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: 13)
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.identifier = id
        }
        if row < filtered.count {
            cell.textField?.stringValue = filtered[row].displayTitle
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    // Double-click = select & confirm
    @objc func tableViewDoubleAction(_ sender: Any?) {
        let row = tableView.clickedRow
        if row >= 0, row < filtered.count {
            selectedItem = filtered[row]
            NSApp.stopModal()
        }
    }
}

// ─── Main ─────────────────────────────────────────────────────

func main() {
    // ── Accessibility trust check ──────────────────────────────
    // AX calls silently return empty results without TCC permission.
    // Check early and fail with a clear message.
    if !AXIsProcessTrusted() {
        fputs("error: Accessibility permission not granted for this binary.\n", stderr)
        fputs("  → System Settings → Privacy & Security → Accessibility\n", stderr)
        fputs("  → Add this executable: \(CommandLine.arguments[0])\n", stderr)
        // Prompt the system dialog (non-blocking) so the user gets the TCC alert
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        exit(1)
    }

    // ── Parse args ─────────────────────────────────────────────
    var targetPID: pid_t? = nil
    var doBenchmark = false
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "-pid":
            if i + 1 < args.count, let p = Int32(args[i + 1]) { targetPID = p; i += 2 }
            else { i += 1 }
        case "-benchmark", "--benchmark":
            doBenchmark = true; benchmarkMode = true; i += 1
        case "-v", "--verbose":
            benchmarkMode = true; i += 1
        default:
            i += 1
        }
    }

    // ── Benchmark mode ─────────────────────────────────────────
    if doBenchmark {
        runBenchmark()
        exit(0)
    }

    // ── Resolve PID ────────────────────────────────────────────
    // IMPORTANT: Resolve BEFORE creating NSApplication or calling
    // setActivationPolicy, so our process doesn't disturb the
    // frontmost-app state that the resolution strategies read.
    let pid: pid_t
    if let explicit = targetPID {
        pid = explicit
    } else if let resolution = resolveFrontmostPID() {
        pid = resolution.pid
    } else {
        fputs("error: could not determine frontmost app PID\n", stderr)
        exit(1)
    }
    guard let targetApp = NSRunningApplication(processIdentifier: pid) else {
        fputs("error: no running app with PID \(pid)\n", stderr)
        exit(1)
    }

    let appName = targetApp.localizedName ?? "Unknown"
    fputs("Target: \(appName) (PID \(pid))\n", stderr)

    // Cache the resolved PID so other Shortcut actions can reuse it
    writePIDCache(pid: pid)

    // ── Ensure target app owns the menu bar ────────────────────
    // When launched from BackgroundShortcutRunner, the target app may
    // have lost menu-bar ownership.  Briefly activate it so AX returns
    // the full menu hierarchy, then we'll take focus for the picker.
    if !(targetApp.isActive && targetApp.ownsMenuBar) {
        fputs("Activating target app to ensure menu-bar ownership…\n", stderr)
        targetApp.activate()
        // Wait for activation to settle — menu bar transfer can take
        // 100-300ms depending on WindowServer load.
        for _ in 0..<20 {
            usleep(50_000) // 50ms
            if targetApp.ownsMenuBar { break }
        }
        if !targetApp.ownsMenuBar {
            fputs("warning: target app may not own menu bar yet; proceeding anyway\n", stderr)
        }
    }

    // ── Enumerate menus (with retry) ───────────────────────────
    var items: [PickerMenuItem] = []
    var menuBar: AXUIElement? = nil
    for attempt in 1...3 {
        let result = loadMenuItems(pid: pid)
        items = result.items
        menuBar = result.menuBar
        if !items.isEmpty { break }
        if attempt < 3 {
            fputs("Retry \(attempt): no menu items yet, waiting…\n", stderr)
            usleep(200_000) // 200ms
        }
    }
    guard !items.isEmpty, let mb = menuBar else {
        // Diagnose: report the AX error for the menu bar attribute
        let axApp = AXUIElementCreateApplication(pid)
        var mbRef: CFTypeRef?
        let axErr = AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &mbRef)
        fputs("error: no menu items found for \(appName) (PID \(pid))\n", stderr)
        fputs("  AXMenuBar query result: \(axErr.rawValue) ", stderr)
        switch axErr {
        case .success:            fputs("(success but empty)\n", stderr)
        case .apiDisabled:        fputs("(API disabled — Accessibility not granted?)\n", stderr)
        case .invalidUIElement:   fputs("(invalid UI element — app may have quit)\n", stderr)
        case .cannotComplete:     fputs("(cannot complete — app not responding?)\n", stderr)
        case .notImplemented:     fputs("(not implemented — app has no menu bar)\n", stderr)
        default:                  fputs("(code \(axErr.rawValue))\n", stderr)
        }
        exit(1)
    }
    fputs("Found \(items.count) menu items\n", stderr)

    // ── Create NSApplication ───────────────────────────────────
    // Done AFTER PID resolution and menu enumeration so that our
    // process's activation doesn't corrupt the frontmost-app state.
    let nsApp = NSApplication.shared
    // .regular is required so macOS treats us as a foreground-capable app.
    nsApp.setActivationPolicy(.regular)

    // ── Show picker ────────────────────────────────────────────
    let picker = PickerWindowController()
    picker.tableView.target = picker
    picker.tableView.doubleAction = #selector(PickerWindowController.tableViewDoubleAction(_:))
    picker.window.title = "Menu Bar Search — \(appName)"

    let chosen = picker.run(items: items)

    guard let selected = chosen else {
        fputs("Cancelled\n", stderr)
        exit(0)
    }

    fputs("Selected: \(selected.label)\n", stderr)

    // ── Reactivate and click ───────────────────────────────────
    targetApp.activate()
    // Wait for the menu bar to transfer before clicking
    for _ in 0..<20 {
        usleep(50_000) // 50ms
        if targetApp.ownsMenuBar { break }
    }

    // Re-enumerate to get a fresh menu bar reference (indices may
    // have shifted if the app rebuilt its menus while we were open).
    let (freshItems, freshMB) = loadMenuItems(pid: pid)
    if let fmb = freshMB, !freshItems.isEmpty {
        // Try to find the same item by label in the fresh enumeration
        if let freshMatch = freshItems.first(where: { $0.label == selected.label }) {
            clickMenuPath(fmb, indices: freshMatch.pathIndices)
        } else {
            // Indices might still be valid; use original
            clickMenuPath(fmb, indices: selected.pathIndices)
        }
    } else {
        // Best effort with the original reference
        clickMenuPath(mb, indices: selected.pathIndices)
    }
    fputs("Clicked: \(selected.label)\n", stderr)
}

main()
