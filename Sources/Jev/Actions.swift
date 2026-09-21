import AppKit
import ApplicationServices

/// Something on screen that can be clicked. `element` is nil for targets found by OCR (see Screen.swift).
struct Target {
    let label: String
    let element: AXUIElement?
    let frame: CGRect
}

/// OS-level actions: open things, type, press shortcuts, click elements found through the Accessibility tree.
enum Actions {
    private static let controls: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTab", "AXDisclosureTriangle", "AXCell", "AXRow", "AXImage", "AXTextField", "AXTextArea", "AXComboBox",
    ]
    private static let editable: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    private struct Node {
        let element: AXUIElement
        let role: String
        let label: String
        let frame: CGRect?
        let inWeb: Bool
    }

    /// Browsers only expose web content to AX after this is set, so call it as soon as an utterance starts.
    static func prepare(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func frame(_ position: Any?, _ size: Any?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
              AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Breadth-first walk of the visible part of the app's focused window.
    // ponytail: capped at 4000 nodes; very long pages may hide elements, raise the cap if targets go missing
    private static func walk(pid: pid_t) -> [Node] {
        let app = AXUIElementCreateApplication(pid)
        let root = attribute(app, "AXFocusedWindow").map { $0 as! AXUIElement } ?? app
        let bounds = frame(attribute(root, "AXPosition"), attribute(root, "AXSize"))
        let names = ["AXRole", "AXTitle", "AXDescription", "AXPosition", "AXSize", "AXChildren", "AXValue"] as CFArray
        var queue: [(AXUIElement, Bool)] = [(root, false)]
        var nodes: [Node] = []
        var i = 0
        while i < queue.count, i < 4000 {
            let (element, inWeb) = queue[i]
            i += 1
            var out: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, [], &out) == .success,
                  let v = out as? [Any], v.count == 7 else { continue }
            let role = v[0] as? String ?? ""
            let rect = frame(v[3], v[4])
            if let rect, let bounds, !rect.intersects(bounds) { continue }  // scrolled out: skip the subtree
            // static text keeps its words in AXValue, everything else in the title or description
            let candidates = [v[1] as? String, v[2] as? String, role == "AXStaticText" ? v[6] as? String : nil]
            let raw = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let label = String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
            nodes.append(Node(element: element, role: role, label: label, frame: rect, inWeb: inWeb))
            for child in v[5] as? [AXUIElement] ?? [] { queue.append((child, inWeb || role == "AXWebArea")) }
        }
        return nodes
    }

    /// Debug aid (`kill -USR1 <pid>`): every named node of the frontmost window, to see how an app exposes its UI.
    static func dump(pid: pid_t) -> String {
        walk(pid: pid).filter { !$0.label.isEmpty }
            .map { "\($0.role)\($0.inWeb ? " [web]" : "") “\($0.label)” \($0.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "")" }
            .joined(separator: "\n")
    }

    /// Clickable things with a name: real controls first, then (in native apps) short pieces of plain text,
    /// which is how chat lists and sidebars usually expose their rows.
    static func targets(pid: pid_t) -> [Target] {
        let nodes = walk(pid: pid)
        func pick(_ keep: (Node) -> Bool) -> [Target] {
            nodes.compactMap { n in
                guard keep(n), !n.label.isEmpty, let f = n.frame, f.width > 1 else { return nil }
                return Target(label: n.label, element: n.element, frame: f)
            }
        }
        // App chrome before page content: "открой вкладку …" means the browser's own tab, not a link on the page.
        // Custom-drawn sidebars (Dia's tabs) show up as AXUnknown or plain static text, so those count too.
        return pick { !$0.inWeb && controls.contains($0.role) }
            + pick { !$0.inWeb && ["AXStaticText", "AXUnknown", "AXGroup"].contains($0.role) }
            + pick { $0.inWeb && controls.contains($0.role) }
    }

    /// Frame of the app's focused window in the same global coordinates mouse clicks use.
    static func windowFrame(pid: pid_t) -> CGRect? {
        guard let w = attribute(AXUIElementCreateApplication(pid), "AXFocusedWindow") else { return nil }
        return frame(attribute(w as! AXUIElement, "AXPosition"), attribute(w as! AXUIElement, "AXSize"))
    }

    private static func focusedFrame() -> (role: String, frame: CGRect?)? {
        guard let f = attribute(AXUIElementCreateSystemWide(), "AXFocusedUIElement") else { return nil }
        let el = f as! AXUIElement
        return (attribute(el, "AXRole") as? String ?? "", frame(attribute(el, "AXPosition"), attribute(el, "AXSize")))
    }

    /// Several elements can share a label (X has two "Post" buttons): take the one nearest the focused field.
    static func click(label: String, among targets: [Target]) {
        let same = targets.filter { $0.label == label }
        let anchor = focusedFrame()?.frame
        let best = anchor.map { anchor in same.min { distance($0.frame, anchor) < distance($1.frame, anchor) } }
            ?? same.max { gapAbove($0, in: targets) < gapAbove($1, in: targets) }
        guard let best else { return }
        if let element = best.element, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        mouseClick(CGPoint(x: best.frame.midX, y: best.frame.midY))
    }

    /// Space between a text line and the nearest line above it in the same column. With no focused field to anchor
    /// on (a chat list read by OCR), the same words can be a row's title and a message preview quoting it: a title
    /// starts a new block, so it has more air above it than a preview line tucked under its own title.
    static func gapAbove(_ t: Target, in all: [Target]) -> CGFloat {
        let above = all.filter { $0.frame.maxY <= t.frame.minY + 2 && abs($0.frame.minX - t.frame.minX) < 160 }
        guard let nearest = above.map(\.frame.maxY).max() else { return .greatestFiniteMagnitude }
        return t.frame.minY - nearest
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private static func mouseClick(_ p: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    /// If no text field has focus, click the first one on the page (web content before browser chrome).
    static func focusTextField(pid: pid_t) {
        if let f = focusedFrame(), editable.contains(f.role) { return }
        let fields = walk(pid: pid).filter { editable.contains($0.role) && $0.frame != nil }
        let rank = { (n: Node) in (n.inWeb ? 0 : 2) + (n.role == "AXTextArea" ? 0 : 1) }
        guard let field = fields.min(by: { rank($0) < rank($1) }), let f = field.frame else { return }
        AXUIElementSetAttributeValue(field.element, "AXFocused" as CFString, kCFBooleanTrue)
        mouseClick(CGPoint(x: f.midX, y: f.midY))
        usleep(150_000)
    }

    static func type(_ text: String) {
        for ch in text {
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.flags = []  // held modifier keys must not leak into the typed characters
                e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e?.post(tap: .cghidEventTap)
            }
            usleep(6_000)
        }
    }

    static func press(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }

    /// System-defined media key event (play/pause, next, previous).
    static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let state = down ? 0xa : 0xb
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: Int((key << 16) | Int32(state << 8)), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Saves a full-screen shot to the Desktop; returns the file name.
    static func screenshot() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Jev Screenshot \(f.string(from: Date())).png"
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(name)").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", path]
        try? p.run()
        return name
    }

    /// Select everything in the focused field and delete it.
    static func deleteText() {
        press(0, .maskCommand)
        press(51)
    }

    /// Runs a config "shell" step in a login zsh, detached; the tail of its output goes to the log.
    static func shell(_ script: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { p in
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log("shell exited \(p.terminationStatus): \(output.suffix(400).replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        do { try p.run() } catch { log("shell failed to start: \(error.localizedDescription)") }
    }

    static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log("applescript failed: \(error)") }
    }

    /// Installed apps by display name.
    static func installedApps() -> [String: URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var apps: [String: URL] = [:]
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"] {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                apps[String(item.dropLast(4))] = URL(fileURLWithPath: dir + "/" + item)
            }
        }
        return apps
    }

    /// Plain string match of a spoken name against app names: exact, then prefix, then substring.
    static func matchApp(_ spoken: String, in names: [String]) -> String? {
        let q = spoken.lowercased()
        guard !q.isEmpty else { return nil }
        let sorted = names.sorted { $0.count < $1.count }
        return sorted.first { $0.lowercased() == q }
            ?? sorted.first { $0.lowercased().hasPrefix(q) }
            ?? sorted.first { $0.lowercased().contains(q) }
    }

    static func launch(_ app: URL) {
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The user's default browser, whatever it is (Dia, Arc, Safari, ...).
    static func defaultBrowser() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
    }

    /// Opens the URL in the default browser. Returns the browser name for the HUD.
    static func open(_ url: URL) -> String {
        NSWorkspace.shared.open(url)
        return defaultBrowser()?.deletingPathExtension().lastPathComponent ?? "browser"
    }
}
