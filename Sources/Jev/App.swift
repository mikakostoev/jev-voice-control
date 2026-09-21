import AppKit
import SwiftUI

/// Pipeline: always listening → utterance → Jev scores the options → decision → OS action.
@MainActor
final class Controller: NSObject {
    private let hud = HUDModel()
    private let listener = Listener()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var targetApp: NSRunningApplication?
    private var active = false  // an utterance is being spoken right now
    private var generation = 0
    private var speculating = false
    private var cached: (heard: String, decision: Decision, sawScreen: Bool)?
    private var previous: (heard: String, decision: Decision)?  // what "ещё" / "повтори" repeats
    private var pendingConfirm: (command: Command, heard: String, probs: [Double], until: Date)?
    private var holdHUD = false                 // keep the card up while a confirmation is pending
    private var configStamp: Date?
    private var screenTargets: [Target] = []   // what was visible when the current utterance began
    private var screenSource = "accessibility"
    private var screenScan: Task<Void, Never>?
    private let dumpSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)

    func start() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(m: hud))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - 240, y: screen.minY))
        }
        panel.orderFrontRegardless()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Jev"
        let menu = NSMenu()
        let pause = menu.addItem(withTitle: "Pause listening", action: #selector(togglePause(_:)), keyEquivalent: "p")
        pause.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit commands…", action: #selector(openConfig), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open log", action: #selector(openLog), keyEquivalent: "l").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Jev", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // `kill -USR1 $(pgrep -x Jev)` writes what Jev can see in the frontmost app to ~/Library/Logs/Jev-ui.log
        signal(SIGUSR1, SIG_IGN)
        dumpSignal.setEventHandler {
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            let pid = app.processIdentifier
            Actions.prepare(pid: pid)
            Task.detached {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // give the app a moment to build its AX tree
                var text = "== \(app.localizedName ?? "?") — accessibility\n" + Actions.dump(pid: pid)
                if Screen.hasAccess {
                    let lines = await Screen.textTargets(pid: pid)
                    text += "\n== screen text\n" + lines.map { "“\($0.label)” \(Int($0.frame.minX)),\(Int($0.frame.minY))" }.joined(separator: "\n")
                }
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jev-ui.log")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                log("ui dump written for \(app.localizedName ?? "?")")
            }
        }
        dumpSignal.resume()

        listener.onPartial = { [weak self] in self?.speculate($0) }
        listener.onFinal = { [weak self] in self?.run($0) }
    }

    /// Listening needs only mic + speech permissions. Accessibility is asked for too, but only typing and
    /// clicking depend on it — opening apps and sites works without.
    func startListening() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log("launch: accessibility trusted=\(AXIsProcessTrustedWithOptions(prompt))")
        Listener.requestPermissions { [self] in
            // "Pause listening" must survive relaunches and rebuilds: a paused mic stays paused until the user resumes it.
            let paused = UserDefaults.standard.bool(forKey: "paused")
            if paused { log("launch: staying paused") }
            listener.setEnabled(!paused)
            refreshPauseUI()
            hud.show(.pill, title: paused ? "Jev is paused" : "Jev is listening")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !self.active { self.hud.hide() }
            }
        }
    }

    @objc private func openConfig() {
        do {
            try Registry.createUserFileIfMissing()
            NSWorkspace.shared.open(Registry.userFile)
        } catch {
            hud.show(.card, title: "Config error", subtitle: error.localizedDescription)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jev.log"))
    }

    /// Loads the commands now and again whenever the user's file is saved. A broken file keeps the previous commands.
    // ponytail: mtime polling every 2 s instead of a file-system watcher — editors replace files on save, which breaks
    // descriptor-based watching; switch to FSEvents if the poll ever matters.
    func watchConfig() {
        reloadConfig(announce: false)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let stamp = (try? FileManager.default.attributesOfItem(atPath: Registry.userFile.path))?[.modificationDate] as? Date
                if stamp != self.configStamp { self.reloadConfig(announce: true) }
            }
        }
    }

    private func reloadConfig(announce: Bool) {
        configStamp = (try? FileManager.default.attributesOfItem(atPath: Registry.userFile.path))?[.modificationDate] as? Date
        do {
            try Registry.load()
            listener.applyConfig()
            log("config: \(Registry.commands.count) commands (\(Registry.userCommandCount) from config.json), locale \(Registry.locale)")
            if announce { hud.show(.card, title: "Config loaded", subtitle: "\(Registry.commands.count) commands, \(Registry.userCommandCount) of them yours") }
        } catch {
            log("config error: \(error.localizedDescription)")
            hud.show(.card, title: "Config error", subtitle: error.localizedDescription, hint: "keeping the previous commands")
        }
        if announce || Registry.commands.isEmpty {
            let gen = generation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self.generation == gen, !self.active { self.hud.hide() }
            }
        }
    }

    private func refreshPauseUI() {
        statusItem.menu?.items.first?.title = listener.enabled ? "Pause listening" : "Resume listening"
        statusItem.button?.title = listener.enabled ? "Jev" : "Jev ⏸"
    }

    @objc private func togglePause(_ item: NSMenuItem) {
        listener.setEnabled(!listener.enabled)
        UserDefaults.standard.set(!listener.enabled, forKey: "paused")
        refreshPauseUI()
        if !listener.enabled { active = false; generation += 1; hud.hide() }
    }

    /// First words of a new utterance: remember which app the command is aimed at.
    private func utteranceBegan() {
        active = true
        generation += 1
        cached = nil
        targetApp = NSWorkspace.shared.frontmostApplication
        screenTargets = []
        if AXIsProcessTrusted(), let pid = targetApp?.processIdentifier {
            Actions.prepare(pid: pid)
            let gen = generation
            screenScan = Task { @MainActor in
                let (targets, source) = await Self.scan(pid: pid)
                if self.generation == gen || !self.active { (self.screenTargets, self.screenSource) = (targets, source) }
            }
        }
        if pendingConfirm == nil { hud.show(.pill, title: "Listening...") }
    }

    private func decide(_ heard: String) async throws -> Decision {
        try await Self.decide(heard: heard, app: targetApp?.localizedName ?? "", previous: previous?.heard ?? "",
                              onScreen: Self.labels(from: screenTargets.map(\.label)))
    }

    /// Stage 1: which action? Jev also gets what is visible in the frontmost app — without it "перемешай" or
    /// "разреши" look like chatter; with it they are obviously the Shuffle / Allow buttons.
    nonisolated static func decide(heard: String, app: String, previous: String, onScreen: [String]) async throws -> Decision {
        try await Jev.choose(
            state: ["heard": heard, "frontmost_app": app, "previous_command": previous, "on_screen": Array(onScreen.prefix(70))],
            instructions: instructions,
            criteria: Registry.criteria(app: app))
    }

    /// While the user is still talking, score partial transcripts so the HUD shows the decision forming live.
    private func speculate(_ partial: String) {
        if !active { utteranceBegan() }
        guard !speculating, pendingConfirm == nil else { return }
        speculating = true
        let gen = generation
        let sawScreen = !screenTargets.isEmpty
        Task { @MainActor in
            defer { self.speculating = false }
            guard let d = try? await self.decide(partial), self.active, self.generation == gen else { return }
            self.cached = (partial, d, sawScreen)
            if let title = Registry[d.choice]?.title, d.confidence >= Registry.minConfidence {
                self.hud.show(.card, title: title, subtitle: partial, probs: d.probs)
            } else {
                self.hud.show(.pill, title: "Listening...", subtitle: partial)
            }
        }
    }

    private func run(_ heard: String) {
        active = false
        generation += 1
        let gen = generation
        guard !heard.isEmpty else { hud.hide(); return }
        Task { @MainActor in
            do {
                if let pending = self.pendingConfirm {
                    self.pendingConfirm = nil
                    if pending.until > Date(), try await self.confirmed(heard) {
                        log("confirm: yes → \(pending.command.id)")
                        try await self.run(pending.command, heard: pending.heard, probs: pending.probs)
                    } else {
                        log("confirm: cancelled \(pending.command.id)")
                        self.hud.show(.card, title: "Cancelled", subtitle: pending.command.title)
                    }
                } else {
                    await self.screenScan?.value
                    let d: Decision
                    if let cached = self.cached, cached.heard == heard, cached.sawScreen || self.screenTargets.isEmpty { d = cached.decision } else { d = try await self.decide(heard) }
                    log("decision: \(d.choice) confidence=\(d.confidence)")
                    try await self.perform(d, heard: heard)
                    log("result: \(self.hud.title) — \(self.hud.subtitle)")
                }
            } catch {
                log("error: \(error.localizedDescription)")
                self.hud.show(.card, title: "Error", subtitle: error.localizedDescription)
            }
            let hold = self.holdHUD
            self.holdHUD = false
            try? await Task.sleep(nanoseconds: hold ? 10_000_000_000 : 1_600_000_000)
            if self.generation == gen {
                if hold, self.pendingConfirm != nil { self.pendingConfirm = nil; log("confirm: timed out") }
                self.hud.hide()
            }
        }
    }

    /// Did the user say yes to the pending command? Anything that is not a clear yes cancels it.
    private func confirmed(_ heard: String) async throws -> Bool {
        let answer = try await Jev.choose(
            state: ["heard": heard],
            instructions: "The assistant asked the user to confirm an action. What did the user answer?",
            criteria: [("yes", "the user confirms: да, давай, подтверждаю, выполняй, ага, yes, do it"),
                       ("no", "the user refuses or cancels: нет, отмена, не надо, стоп, no, cancel"),
                       ("other", "something unrelated to the question")])
        return answer.choice == "yes" && answer.confidence >= Registry.minConfidence
    }

    /// Act when Jev is confident, or when it is torn between real commands while "not a command" is ruled out.
    nonisolated static func wouldAct(_ d: Decision) -> Bool {
        let surelyCommand = (d.probs.last ?? 1) <= 0.1 && d.confidence >= 0.4
        return d.choice != "none" && (d.confidence >= Registry.minConfidence || surelyCommand)
    }

    nonisolated static let instructions = "A voice command was transcribed, possibly only partially. Which computer action does it ask for? on_screen lists the items currently visible in the frontmost app: when the command names or describes one of them (in any language, by meaning: перешли = Forward, разреши = Allow, перемешай = Shuffle / Перемешать), the action is click, unless one of the other specific actions clearly fits better. Casual talk that merely shares a word with on_screen is still not a command."

    private func perform(_ d: Decision, heard: String) async throws {
        var d = d, heard = heard
        if Registry[d.choice]?.kind == "repeat", d.confidence >= Registry.minConfidence {
            guard let previous else {
                hud.show(.card, title: "Again", subtitle: "Nothing to repeat yet", probs: d.probs)
                return
            }
            (heard, d) = previous
        } else if d.choice != "none" {
            previous = (heard, d)
        }
        let command = Registry[d.choice]
        let kind = command?.kind
        let opening = kind == "open_app" || kind == "open_url"
        // A dictionary hit ("открой яндекс карты") is strong evidence even when Jev is torn between app and site.
        let known = opening ? Parse.knownSite(from: heard) : nil
        // Torn between commands ("открой видео про макбук": search? open?) while the screen has an obvious match → click it.
        if command != nil, kind != "click", d.confidence < Registry.minConfidence, known == nil, AXIsProcessTrusted() {
            let labels = Self.labels(from: screenTargets.map(\.label))
            if !labels.isEmpty, let pick = try? await Self.pickTarget(heard: heard, app: targetApp?.localizedName ?? "", labels: labels),
               pick.choice != Self.nothing, pick.confidence >= Registry.minConfidence {
                log("rescue: \(d.choice) (\(d.confidence)) → click “\(pick.choice)”")
                return try await click(heard, probs: d.probs)
            }
        }
        guard let command, Self.wouldAct(d) || known != nil else {
            hud.hide()  // background talk is the normal case when always listening — stay out of the way
            return
        }
        if command.steps.contains(where: \.needsAccessibility), !AXIsProcessTrusted() {
            hud.show(.card, title: "No access", subtitle: "Enable Jev in Settings → Accessibility", probs: d.probs)
            return
        }
        if command.confirm {
            pendingConfirm = (command, heard, d.probs, Date().addingTimeInterval(10))
            hud.show(.card, title: "\(command.title)?", subtitle: "Say «да» to run, «отмена» to cancel", hint: command.id, probs: d.probs)
            log("confirm: waiting for a yes to run \(command.id)")
            holdHUD = true
            return
        }
        try await run(command, heard: heard, probs: d.probs)
    }

    /// Executes a command's steps in order. Built-in steps render their own HUD cards; plain ones share a generic card.
    private func run(_ command: Command, heard: String, probs: [Double]) async throws {
        if command.steps.allSatisfy({ $0.builtinName == nil }) {
            hud.show(.card, title: command.title, subtitle: "Action sent: \(command.title)", hint: targetApp?.localizedName ?? "", probs: probs)
            hud.confirm()
        }
        let pid = targetApp?.processIdentifier
        for step in command.steps {
            switch step {
            case .keys(let combo):
                guard let (key, flags) = Keys.parse(combo) else { continue }
                await Task.detached { Actions.press(key, flags) }.value
                try await Task.sleep(nanoseconds: 120_000_000)
            case .type(let text):
                await Task.detached {
                    if let pid { Actions.focusTextField(pid: pid) }
                    Actions.type(text)
                }.value
            case .open(let what):
                try await open("open " + what, preferApp: !what.contains("."), known: nil, probs: probs, elseClick: false, literal: what)
            case .click(let label):
                try await click("нажми " + label, probs: probs)
            case .shell(let script):
                Actions.shell(script)
            case .applescript(let source):
                Actions.runAppleScript(source)
            case .media(let name):
                if let key = Step.mediaKeys[name] { Actions.mediaKey(key) }
            case .wait(let seconds):
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            case .builtin(let name):
                try await builtin(name, heard: heard, probs: probs)
            }
        }
    }

    private func builtin(_ name: String, heard: String, probs: [Double]) async throws {
        let pid = targetApp?.processIdentifier
        switch name {
        case "open_app", "open_url":
            try await open(heard, preferApp: name == "open_app", known: Parse.knownSite(from: heard), probs: probs)

        case "search":
            guard let url = Parse.search(from: heard) else {
                hud.show(.card, title: "Search", subtitle: "Nothing to search for", probs: probs)
                return
            }
            let browser = Actions.open(url)
            hud.show(.card, title: "Search", subtitle: heard, hint: "\(url.host ?? "") in \(browser)", probs: probs)
            hud.confirm()

        case "type_text":
            let text = Parse.text(from: heard)
            hud.show(.card, title: "Type", subtitle: "type in \(text)", probs: probs)
            await Task.detached {
                if let pid { Actions.focusTextField(pid: pid) }
                Actions.type(text)
            }.value
            hud.confirm()

        case "emoji":
            if let emoji = Parse.emoji(from: heard) {
                hud.show(.card, title: emoji, subtitle: "type in \(emoji)", probs: probs)
                await Task.detached { Actions.type(emoji) }.value
            } else {  // unknown name: let the user pick in the system emoji panel
                hud.show(.card, title: "Emoji", subtitle: "Pick one in the emoji panel", probs: probs)
                await Task.detached { Actions.press(49, [.maskCommand, .maskControl]) }.value  // ⌃⌘Space
            }
            hud.confirm()

        case "set_volume":
            guard let level = Parse.volume(from: heard) else {
                hud.show(.card, title: "Volume", subtitle: "What level?", probs: probs)
                return
            }
            Actions.runAppleScript("set volume output volume \(level)")
            hud.show(.card, title: "Volume", subtitle: "Volume \(level)%", probs: probs)
            hud.confirm()

        case "open_folder":
            guard let folder = Parse.folder(from: heard) else {  // not a folder we know — maybe an app after all
                try await open(heard, preferApp: true, known: nil, probs: probs)
                return
            }
            NSWorkspace.shared.open(folder)
            hud.show(.card, title: "Open", subtitle: "Open \(folder.lastPathComponent)", hint: "Finder", probs: probs)
            hud.confirm()

        case "screenshot":
            let file = Actions.screenshot()
            hud.show(.card, title: "Screenshot", subtitle: "Saved to Desktop", hint: file, probs: probs)
            hud.confirm()

        case "quit_app":
            try await quit(heard, probs: probs)

        case "click":
            try await click(heard, probs: probs, elseOpen: true)

        default:
            break  // "repeat" is resolved before the steps run
        }
    }

    /// "Открой …" can mean an app, a site, the default browser, or even something on screen — resolve in that order.
    private func open(_ heard: String, preferApp: Bool, known: (key: String, url: URL)?, probs: [Double], elseClick: Bool = true, literal: String? = nil) async throws {
        func opened(_ what: String, hint: String) {
            hud.show(.card, title: "Open", subtitle: "Open \(what)", hint: hint, probs: probs)
            hud.confirm()
        }
        func openSite(_ url: URL) {
            let browser = Actions.open(url)
            opened("\(url.host ?? "") in \(browser)", hint: "Go to \(url.host ?? "")")
        }
        if let literal, literal.hasPrefix("/") || literal.hasPrefix("~") {  // {"open": "~/Projects"} from a config
            NSWorkspace.shared.open(URL(fileURLWithPath: NSString(string: literal).expandingTildeInPath))
            return opened(literal, hint: "Finder")
        }
        if let literal, literal.contains("://"), let url = URL(string: literal) { return openSite(url) }
        let spoken = literal ?? Parse.app(from: heard)
        if Parse.isBrowser(spoken), let browser = Actions.defaultBrowser() {
            Actions.launch(browser)
            let name = browser.deletingPathExtension().lastPathComponent
            return opened(name, hint: "Default browser")
        }
        if let url = Parse.explicitURL(from: heard) { return openSite(url) }

        let apps = Actions.installedApps()
        var name = Actions.matchApp(spoken, in: Array(apps.keys))
        let appLike = known.map { Parse.alsoApps.contains($0.key) } ?? false
        if name == nil, let known, !appLike { return openSite(known.url) }  // else Jev maps "яндекс карты" to Maps.app
        if name == nil, !spoken.isEmpty, preferApp || appLike {
            // "телеграм", nicknames: let Jev match the spoken name to an installed app
            let nothing = "(not installed)"
            let pick = try await Jev.choose(
                state: ["spoken_app_name": spoken],
                instructions: "Which installed application is the user naming? The name may be spoken in another language or abbreviated.",
                criteria: apps.keys.sorted().map { ($0, "the application \($0)") } + [(nothing, "none of these applications")])
            if pick.choice != nothing, pick.confidence >= Registry.minConfidence { name = pick.choice }
        }
        if let name, let url = apps[name] {
            Actions.launch(url)
            return opened(name, hint: "Launch \(name).app")
        }
        if let known { return openSite(known.url) }
        if !preferApp, let url = Parse.url(from: heard) { return openSite(url) }
        if elseClick, !spoken.isEmpty, AXIsProcessTrusted() { return try await click(heard, probs: probs) }  // "открой диалог с Машей"
        hud.show(.card, title: "Open", subtitle: spoken.isEmpty ? "Open what?" : "Nothing named “\(spoken)”", probs: probs)
    }

    /// Clickable things in the app: Accessibility first, screen OCR when the app exposes almost nothing (Telegram).
    nonisolated static func scan(pid: pid_t) async -> ([Target], String) {
        var targets = await Task.detached { Actions.targets(pid: pid) }.value
        guard Set(targets.map(\.label)).count < 5, Screen.hasAccess else { return (targets, "accessibility") }
        targets += await Screen.textTargets(pid: pid)
        return (targets, "screen text")
    }

    nonisolated static let nothing = "(nothing matches)"

    /// Unique labels worth offering to Jev: OCR noise like "08:22", "89" or "✓✓" has no letters and is dropped.
    nonisolated static func labels(from raw: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for label in raw where label.filter(\.isLetter).count >= 2 && seen.insert(label).inserted && out.count < 120 {
            out.append(label)
        }
        return out
    }

    /// Second decision: which visible item the command means. Positions let "первый результат" / "второй чат" work.
    nonisolated static func pickTarget(heard: String, app: String, labels: [String]) async throws -> Decision {
        try await Jev.choose(
            state: ["heard": heard, "frontmost_app": app],
            instructions: "A voice command asks to click or open one item visible on screen. Pick the item whose text best matches the MEANING of the command. Commands are usually spoken in Russian while items may be in English or Russian, so match across languages and word forms (перешли = Forward, ответь = Reply, удали = Delete, разреши = Allow, макбук = MacBook, фотками = Фото, плова = плов). An item may be named by its topic, by a part of its text, or by what it does.",
            criteria: labels.enumerated().map { ($1, "on-screen item #\($0 + 1) in reading order: “\($1)”") }
                + [(nothing, "no item on screen is related to the command at all")])
    }

    /// The pick is good when Jev is confident, or when it leans to an item while "nothing matches" is nearly ruled out.
    nonisolated static func accepted(_ pick: Decision) -> Bool {
        pick.choice != nothing && (pick.confidence >= Registry.minConfidence || ((pick.probs.last ?? 1) <= 0.3 && pick.confidence >= 0.3))
    }

    /// A second decision picks the element among what is visible: Accessibility first, OCR when the app exposes nothing.
    private func click(_ heard: String, probs: [Double], elseOpen: Bool = false) async throws {
        guard let pid = targetApp?.processIdentifier else { return }
        await screenScan?.value  // normally finished long before the user stops talking
        var (targets, source) = (screenTargets, screenSource)
        if targets.isEmpty { (targets, source) = await Self.scan(pid: pid) }
        if Set(targets.map(\.label)).count < 5, !Screen.hasAccess {
            Screen.requestAccess()
            hud.show(.card, title: "No access", subtitle: "Enable Jev in Settings → Screen Recording", hint: "\(targetApp?.localizedName ?? "This app") hides its buttons", probs: probs)
            return
        }
        let labels = Self.labels(from: targets.map(\.label))
        log("click: \(labels.count) targets via \(source) in \(targetApp?.localizedName ?? "?")")
        guard !labels.isEmpty else {
            hud.show(.card, title: "Click", subtitle: "Nothing clickable found", probs: probs)
            return
        }
        let nothing = Self.nothing
        let pick = try await Self.pickTarget(heard: heard, app: targetApp?.localizedName ?? "", labels: labels)
        guard Self.accepted(pick) else {
            log("click: no match (best “\(pick.choice)” \(pick.confidence)) among \(labels.count) targets")
            // "открой настройки" with no such button on screen: the user meant the app, not a control
            if elseOpen, Parse.app(from: heard) != heard.trimmingCharacters(in: .whitespaces) {
                return try await open(heard, preferApp: true, known: Parse.knownSite(from: heard), probs: probs, elseClick: false)
            }
            hud.show(.card, title: "No match", subtitle: heard, probs: pick.probs)
            return
        }
        hud.show(.card, title: pick.choice, subtitle: "Action sent: \(pick.choice)", hint: "Click “\(pick.choice)”", probs: pick.probs)
        hud.confirm()
        await Task.detached { Actions.click(label: pick.choice, among: targets) }.value
    }

    /// "закрой телеграм" quits Telegram even when another app is in front; "закрой приложение" quits the current one.
    private func quit(_ heard: String, probs: [Double]) async throws {
        let spoken = Parse.quitTarget(from: heard)
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let names = running.compactMap(\.localizedName)
        var name = spoken.isEmpty ? targetApp?.localizedName : Actions.matchApp(spoken, in: names)
        if name == nil {
            let nothing = "(not running)"
            let pick = try await Jev.choose(
                state: ["spoken_app_name": spoken],
                instructions: "Which running application is the user naming? The name may be spoken in another language or abbreviated.",
                criteria: names.map { ($0, "the application \($0)") } + [(nothing, "none of these applications")])
            if pick.choice != nothing, pick.confidence >= Registry.minConfidence { name = pick.choice }
        }
        guard let name, let app = running.first(where: { $0.localizedName == name }) else {
            hud.show(.card, title: "Quit", subtitle: "“\(spoken)” is not running", probs: probs)
            return
        }
        app.terminate()
        hud.show(.card, title: "Quit", subtitle: "Quit \(name)", probs: probs)
        hud.confirm()
    }

    /// Scripted HUD walkthrough (no mic, no permissions, no actions) — `Jev --demo`.
    func demo() {
        let steps: [(Double, () -> Void)] = [
            (0.5, { self.hud.show(.pill, title: "Listening...") }),
            (2.0, { self.hud.show(.card, title: "Open", subtitle: "Open x.com in Chrome", probs: [0.1, 0.8, 0.05, 0.05, 0]) }),
            (3.2, { self.hud.confirm() }),
            (4.2, { self.hud.show(.pill, title: "Listening...") }),
            (5.4, { self.hud.show(.card, title: "Type", subtitle: "type in hello", probs: [0, 0.05, 0.6, 0.3, 0.05]) }),
            (6.2, { self.hud.show(.card, title: "Type", subtitle: "type in hello world", probs: [0, 0, 1, 0, 0]) }),
            (7.0, { self.hud.confirm() }),
            (8.0, { self.hud.show(.pill, title: "Listening...") }),
            (9.2, { self.hud.show(.card, title: "Post", subtitle: "Action sent: Post", hint: "Click “Post”", probs: [0, 0, 0, 0, 0, 1, 0, 0]) }),
            (9.3, { self.hud.confirm() }),
            (11.0, { self.hud.hide() }),
            (12.0, { NSApp.terminate(nil) }),
        ]
        for (at, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: step) }
    }
}

@main
@MainActor
struct Main {
    static func main() async {
        if CommandLine.arguments.contains("--init-config") {  // same as "Edit commands…" in the menu, minus opening the editor
            do { try Registry.createUserFileIfMissing(); print(Registry.userFile.path) } catch { print(error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--eval") || CommandLine.arguments.contains("--eval-clicks") {
            do { try Registry.load() } catch { print("config error: \(error.localizedDescription)"); exit(2) }
        }
        if CommandLine.arguments.contains("--selftest") { await selftest(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--eval-clicks"), CommandLine.arguments.count > i + 1 {
            await evalClicks(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--eval"), CommandLine.arguments.count > i + 1 {
            await eval(CommandLine.arguments[i + 1])
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = Controller()
        controller.start()
        controller.watchConfig()
        if CommandLine.arguments.contains("--demo") { controller.demo() } else { controller.startListening() }
        withExtendedLifetime(controller) { app.run() }
    }

    /// `Jev --eval cases.tsv`: runs every "phrase<TAB>expected action[<TAB>previous command[<TAB>frontmost app]]" line through the real
    /// Jev decision and the act/ignore gate, and prints the misses. "none" passes when Jev would stay quiet.
    static func eval(_ path: String) async {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); exit(1) }
        let cases = text.split(separator: "\n").filter { !$0.hasPrefix("#") && $0.contains("\t") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        var failures: [String] = []
        await withTaskGroup(of: String?.self) { group in
            var next = 0
            func add() {
                guard next < cases.count else { return }
                let c = cases[next]; next += 1
                group.addTask {
                    guard let d = try? await Controller.decide(heard: c[0], app: c.count > 3 ? c[3] : "", previous: c.count > 2 ? c[2] : "", onScreen: []) else {
                        return "ERROR  \(c[0])"
                    }
                    let got = Controller.wouldAct(d) ? d.choice : "none"
                    return c[1].split(separator: "|").contains(Substring(got)) ? nil : "MISS   “\(c[0])” expected \(c[1]), got \(d.choice) (\(String(format: "%.2f", d.confidence)))"
                }
            }
            for _ in 0..<6 { add() }  // six requests in flight
            for await result in group {
                if let result { failures.append(result) }
                add()
            }
        }
        failures.sorted().forEach { print($0) }
        print("\(cases.count - failures.count)/\(cases.count) passed")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// `Jev --eval-clicks clicks.tsv`: app screens (lists of visible labels) and commands that must land on one label.
    /// File format: "@screen name | App" starts a screen, "> phrase<TAB>expected label" is a case, other lines are labels.
    static func evalClicks(_ path: String) async {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); exit(1) }
        struct Case { let screen: String, app: String, labels: [String], phrase: String, expected: String, alsoFine: [String] }
        var cases: [Case] = [], pending: [(String, String, [String])] = []
        var screen = "", app = "", labels: [String] = []
        func flush() { cases += pending.map { Case(screen: screen, app: app, labels: Controller.labels(from: labels), phrase: $0.0, expected: $0.1, alsoFine: $0.2) }; pending = [] }
        for line in text.split(separator: "\n").map(String.init) where !line.hasPrefix("#") {
            if line.hasPrefix("@screen ") {
                flush()
                let parts = line.dropFirst(8).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                (screen, app, labels) = (parts[0], parts.count > 1 ? parts[1] : "", [])
            } else if line.hasPrefix("> ") {
                let parts = line.dropFirst(2).split(separator: "\t").map(String.init)
                if parts.count >= 2 { pending.append((parts[0], parts[1], parts.count > 2 ? parts[2].split(separator: "|").map(String.init) : [])) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                labels.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        var failures: [String] = []
        await withTaskGroup(of: String?.self) { group in
            var next = 0
            func add() {
                guard next < cases.count else { return }
                let c = cases[next]; next += 1
                group.addTask {
                    // stage 1 with the screen in view: real commands must route to click, "(ignore)" lines must stay quiet
                    guard let first = try? await Controller.decide(heard: c.phrase, app: c.app, previous: "", onScreen: c.labels) else { return "ERROR  [\(c.screen)] \(c.phrase)" }
                    let action = Controller.wouldAct(first) ? first.choice : "none"
                    if c.expected == "(ignore)" {
                        return action == "none" ? nil : "MISS 1 [\(c.screen)] “\(c.phrase)” must be ignored, got \(first.choice) (\(String(format: "%.2f", first.confidence)))"
                    }
                    if c.alsoFine.contains(action) { return nil }  // e.g. "отмена" → Escape closes the dialog just as well
                    // open_* falls back to a click in the app, and a torn decision is rescued by a confident on-screen match
                    let reachesPicker = ["click", "open_app", "open_url", "open_folder"].contains(action)
                        || (first.choice != "none" && first.confidence < 0.6)
                    if c.expected != Controller.nothing, !reachesPicker {
                        return "MISS 1 [\(c.screen)] “\(c.phrase)” expected click, got \(first.choice) (\(String(format: "%.2f", first.confidence)))"
                    }
                    guard let d = try? await Controller.pickTarget(heard: c.phrase, app: c.app, labels: c.labels) else { return "ERROR  [\(c.screen)] \(c.phrase)" }
                    let got = Controller.accepted(d) ? d.choice : Controller.nothing
                    let ok = c.expected.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.contains(got)
                    return ok ? nil : "MISS 2 [\(c.screen)] “\(c.phrase)” expected “\(c.expected)”, got “\(d.choice)” (\(String(format: "%.2f", d.confidence)), nothing=\(String(format: "%.2f", d.probs.last ?? 0)))"
                }
            }
            for _ in 0..<6 { add() }
            for await result in group {
                if let result { failures.append(result) }
                add()
            }
        }
        failures.sorted().forEach { print($0) }
        print("\(cases.count - failures.count)/\(cases.count) passed")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// `Jev --selftest`: transcript parsing, the bell-curve maths, and one live Jev call.
    static func selftest() async {
        precondition(Parse.text(from: "Type in hello world") == "hello world")
        precondition(Parse.text(from: "write Hi there") == "Hi there")
        precondition(Parse.url(from: "Open X.com in Brave browser")?.absoluteString == "https://x.com")
        precondition(Parse.url(from: "go to github dot com")?.absoluteString == "https://github.com")
        precondition(Parse.url(from: "open youtube in the browser")?.absoluteString == "https://youtube.com")
        precondition(Parse.url(from: "open") == nil)
        precondition(Parse.url(from: "Открой ютуб в браузере")?.absoluteString == "https://youtube.com")
        precondition(Parse.url(from: "открой сайт Яндекс Карты.")?.absoluteString == "https://yandex.ru/maps")
        precondition(Parse.url(from: "перейди на тик ток")?.absoluteString == "https://tiktok.com")
        precondition(Parse.url(from: "open twitter")?.absoluteString == "https://x.com")
        precondition(Parse.url(from: "открой неизвестныйсайт") == nil)
        precondition(Parse.knownSite(from: "Открой Яндекс карты")?.key == "яндекс карты")
        precondition(Parse.knownSite(from: "открой телеграм").map { Parse.alsoApps.contains($0.key) } == true)
        precondition(Parse.knownSite(from: "открой калькулятор") == nil)
        precondition(Parse.app(from: "Open Telegram") == "Telegram")
        precondition(Parse.isBrowser(Parse.app(from: "Зайди в браузер")))
        precondition(!Parse.isBrowser(Parse.app(from: "открой телеграм")))
        precondition(Parse.knownSite(from: "Включи YouTube")?.key == "youtube")
        precondition(Parse.quitTarget(from: "закрой телеграм") == "телеграм")
        precondition(Parse.quitTarget(from: "закрой приложение") == "")
        precondition(Parse.quitTarget(from: "quit Apple Music") == "Apple Music")
        precondition(Parse.search(from: "найди на ютубе лофи музыку")?.absoluteString.hasPrefix("https://www.youtube.com/results?search_query=") == true)
        precondition(Parse.search(from: "загугли погоду в Париже")?.host == "www.google.com")
        precondition(Parse.search(from: "найди") == nil)
        precondition(Parse.volume(from: "громкость 50") == 50 && Parse.volume(from: "звук на максимум") == 100)
        precondition(Parse.folder(from: "открой загрузки")?.lastPathComponent == "Downloads")
        precondition(Parse.emoji(from: "Поставь эмодзи сердечко") == "❤️")
        precondition(Parse.text(from: "Напиши спасибо большое и поставь эмодзи сердечко") == "спасибо большое ❤️")
        precondition(Parse.text(from: "напиши привет смайлик огонь") == "привет 🔥")
        precondition(Parse.text(from: "напиши я поставил чайник") == "я поставил чайник")
        precondition(Controller.labels(from: ["Мама", "08:22", "89", "Мама", "✓✓", "OK", "1 сезон"]) == ["Мама", "OK", "1 сезон"])
        // A chat list as OCR sees it: "Анна" is both a preview line quoted inside the "Поездка" row and a row title
        let line = { (label: String, x: CGFloat, y: CGFloat) in Target(label: label, element: nil, frame: CGRect(x: x, y: y, width: 80, height: 13)) }
        let list = [line("Поездка", 94, 368), line("Документы", 100, 390), line("Анна", 78, 409),
                    line("Сергей", 78, 581), line("Скинул файл", 78, 600), line("посмотри вечером", 78, 619), line("Анна", 78, 653)]
        let dupes = list.filter { $0.label == "Анна" }
        precondition(dupes.max { Actions.gapAbove($0, in: list) < Actions.gapAbove($1, in: list) }?.frame.minY == 653, "the row title wins over the quoted preview")
        // config format
        precondition(Registry.criteria(app: "").last?.0 == "none", "wouldAct() reads P(none) from the last slot")
        precondition(Registry.commands.count >= 60 && Registry["close_tab"]?.steps.count == 1)
        precondition(Keys.parse("cmd+shift+t")! == (17, [.maskCommand, .maskShift]) && Keys.parse("alt+down")!.key == 125)
        precondition(Keys.parse("cmd+bogus") == nil && Keys.parse("hyper+t") == nil)
        let decode = { (json: String) in try JSONDecoder().decode(Command.self, from: Data(json.utf8)) }
        let deploy = try! decode(#"{"id":"deploy","say":"выкати на прод","do":[{"shell":"./deploy.sh"}]}"#)
        precondition(deploy.confirm && deploy.title == "Deploy", "shell steps ask for confirmation unless told otherwise")
        precondition(try! decode(#"{"id":"x","say":"s","confirm":false,"do":[{"shell":"ls"}]}"#).confirm == false)
        precondition(try! decode(#"{"id":"next_chat","app":"Telegram","say":"следующий чат","do":[{"keys":"alt+down"}]}"#).confirm == false)
        precondition((try? decode(#"{"id":"x","say":"s","do":[{"keys":"cmd+nope"}]}"#)) == nil, "bad shortcut is rejected")
        precondition((try? decode(#"{"id":"x","say":"s","do":[{"keys":"cmd+t","type":"hi"}]}"#)) == nil, "one action per step")
        precondition((try? decode(#"{"id":"x","say":"s","do":[{"builtin":"teleport"}]}"#)) == nil, "unknown builtin is rejected")
        precondition((try? decode(#"{"id":"none","say":"s","do":[{"wait":1}]}"#)) == nil && (try? decode(#"{"id":"x","say":"s","do":[]}"#)) == nil)
        precondition(Parse.app(from: "открой приложение Заметки") == "Заметки")
        precondition(Actions.matchApp("telegram", in: ["Telegram Lite", "Telegram", "Notes"]) == "Telegram")
        precondition(Actions.matchApp("chrome", in: ["Google Chrome", "Notes"]) == "Google Chrome")
        precondition(Actions.matchApp("телеграм", in: ["Telegram"]) == nil)

        let curve = DensityField.target([0, 0, 1, 0], 0)
        precondition(curve.firstIndex(of: curve.max()!)! * 4 / curve.count == 2, "peak sits over the chosen option")

        do {
            let started = Date()
            let d = try await Jev.choose(
                state: ["heard": "type in hello world"],
                instructions: "Which computer action does the voice command ask for?",
                criteria: Registry.criteria(app: ""))
            let apps = Actions.installedApps().keys.sorted()
            let app = try await Jev.choose(
                state: ["spoken_app_name": "телеграм"],
                instructions: "Which installed application is the user naming? The name may be spoken in another language or abbreviated.",
                criteria: apps.map { ($0, "the application \($0)") } + [("(not installed)", "none of these applications")])
            print("телеграм -> \(app.choice) (\(app.confidence)) among \(apps.count) apps")
            precondition(d.choice == "type_text", "got \(d.choice)")
            print("jev ok: \(d.choice) (\(d.confidence)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            print("jev FAILED: \(error.localizedDescription)")
            exit(1)
        }
        print("selftest passed")
    }
}
