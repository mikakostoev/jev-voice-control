import AppKit

/// One thing a command does. In JSON a step is an object with exactly one key: {"keys": "cmd+t"}.
enum Step: Decodable {
    case keys(String)          // keyboard shortcut in the frontmost app
    case open(String)          // URL, file/folder path, or application name
    case type(String)          // text typed into the focused field
    case click(String)         // an on-screen item, named the way you would say it
    case shell(String)         // zsh command
    case applescript(String)
    case wait(Double)          // seconds
    case media(String)         // play | next | previous
    case builtin(String)       // Jev's own smart actions, see Step.builtins

    static let builtins: Set<String> = [
        "open_app", "open_url", "search", "type_text", "click", "quit_app", "repeat", "emoji", "set_volume", "open_folder", "screenshot",
    ]
    static let mediaKeys: [String: Int32] = ["play": 16, "next": 17, "previous": 18]  // NX_KEYTYPE_*

    private enum Key: String, CodingKey, CaseIterable {
        case keys, open, type, click, shell, applescript, wait, media, builtin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func fail(_ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
        }
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw fail("a step needs exactly one of: " + Key.allCases.map(\.rawValue).joined(separator: ", "))
        }
        switch key {
        case .keys:
            let s = try c.decode(String.self, forKey: key)
            guard Keys.parse(s) != nil else { throw fail("unknown key combination “\(s)” (example: cmd+shift+t)") }
            self = .keys(s)
        case .open: self = .open(try c.decode(String.self, forKey: key))
        case .type: self = .type(try c.decode(String.self, forKey: key))
        case .click: self = .click(try c.decode(String.self, forKey: key))
        case .shell: self = .shell(try c.decode(String.self, forKey: key))
        case .applescript: self = .applescript(try c.decode(String.self, forKey: key))
        case .wait: self = .wait(try c.decode(Double.self, forKey: key))
        case .media:
            let s = try c.decode(String.self, forKey: key)
            guard Step.mediaKeys[s] != nil else { throw fail("media must be one of: play, next, previous") }
            self = .media(s)
        case .builtin:
            let s = try c.decode(String.self, forKey: key)
            guard Step.builtins.contains(s) else { throw fail("unknown builtin “\(s)”; available: " + Step.builtins.sorted().joined(separator: ", ")) }
            self = .builtin(s)
        }
    }

    var builtinName: String? { if case .builtin(let name) = self { return name } else { return nil } }

    /// Steps that drive the frontmost app through synthetic input need the Accessibility permission.
    var needsAccessibility: Bool {
        switch self {
        case .keys, .type, .click, .media: return true
        case .builtin(let name): return ["type_text", "click", "emoji"].contains(name)
        default: return false
        }
    }

    /// Arbitrary code by voice, with an always-on microphone: these ask for a spoken "да" unless the command opts out.
    var isDangerous: Bool {
        switch self {
        case .shell, .applescript: return true
        default: return false
        }
    }
}

/// "cmd+shift+t" → key code + modifier flags.
enum Keys {
    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "enter": 36, "return": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "alt": .maskAlternate, "opt": .maskAlternate,
        "option": .maskAlternate, "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn,
    ]

    static func parse(_ combo: String) -> (key: CGKeyCode, flags: CGEventFlags)? {
        var parts = combo.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, parts.suffix(2) == ["", ""] { parts.removeLast(2); parts.append("+") }  // "cmd++"
        guard let last = parts.last, let key = last == "+" ? 24 : codes[last] else { return nil }
        var flags: CGEventFlags = last == "+" ? .maskShift : []
        for name in parts.dropLast() {
            guard let flag = modifiers[name] else { return nil }
            flags.insert(flag)
        }
        return (key, flags)
    }
}

struct Command: Decodable {
    let id: String
    let say: String            // what Jev reads to recognise the command: a description plus example phrases
    let title: String
    let app: String?           // only offered while this app is frontmost
    let confirm: Bool
    let steps: [Step]

    private enum CodingKeys: String, CodingKey { case id, say, title, app, confirm, steps = "do" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        say = try c.decode(String.self, forKey: .say)
        steps = try c.decode([Step].self, forKey: .steps)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? id.replacingOccurrences(of: "_", with: " ").prefix(1).uppercased() + id.replacingOccurrences(of: "_", with: " ").dropFirst()
        confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? steps.contains(where: \.isDangerous)
        func fail(_ message: String) -> DecodingError { .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message)) }
        if id == "none" || id.isEmpty { throw fail("“\(id)” cannot be used as a command id") }
        if say.trimmingCharacters(in: .whitespaces).isEmpty { throw fail("command “\(id)” needs a “say” description") }
        if steps.isEmpty { throw fail("command “\(id)” has an empty “do” list") }
    }

    var kind: String? { steps.first?.builtinName }
}

private struct ConfigFile: Decodable {
    var locale: String?
    var minConfidence: Double?
    var silence: Double?
    var commands: [Command]?
    var disable: [String]?
    var sites: [String: String]?
    var emoji: [String: String]?
}

struct ConfigError: LocalizedError { let errorDescription: String? }

/// Built-in commands (defaults.json inside the app) + the user's ~/.config/jev/config.json on top.
/// Loaded on the main thread at launch and whenever the user file changes.
enum Registry {
    /// ~/.config/jev/config.json, or $JEV_CONFIG (handy for trying a config without touching the real one)
    static let userFile = env["JEV_CONFIG"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/jev/config.json")
    static let noneOption = ("none", "not a command for the computer: chatter, a question, thinking aloud, or noise")

    private(set) static var commands: [Command] = []
    private(set) static var locale = env["JEV_LOCALE"] ?? "en-US"
    private(set) static var minConfidence = 0.6
    private(set) static var silence = 0.9
    private(set) static var userCommandCount = 0

    static subscript(id: String) -> Command? { commands.first { $0.id == id } }

    /// The options offered to Jev: global commands plus the ones bound to the frontmost app. "none" is always last.
    static func criteria(app: String) -> [(String, String)] {
        commands.filter { c in c.app.map { app.localizedCaseInsensitiveContains($0) } ?? true }.map { ($0.id, $0.say) } + [noneOption]
    }

    private static var defaultsFile: URL? {
        [Bundle.main.resourceURL?.appendingPathComponent("defaults.json"), URL(fileURLWithPath: "defaults.json")]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func decode(_ url: URL) throws -> ConfigFile {
        do {
            return try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw ConfigError(errorDescription: "\(url.lastPathComponent): \(describe(error))")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? "." + $0.stringValue }.joined().drop { $0 == "." }
            return p.isEmpty ? "" : " at \(p)"
        }
        switch error {
        case .dataCorrupted(let c):
            let syntax = (c.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String  // has line and column
            return (syntax ?? c.debugDescription) + path(c)
        case .keyNotFound(let key, let c): return "missing “\(key.stringValue)”" + path(c)
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return c.debugDescription + path(c)
        @unknown default: return error.localizedDescription
        }
    }

    /// Throws without touching the current state, so a broken edit never takes Jev down.
    static func load() throws {
        guard let defaultsFile else { throw ConfigError(errorDescription: "defaults.json is missing from the app") }
        var merged = try decode(defaultsFile).commands ?? []
        let user = FileManager.default.fileExists(atPath: userFile.path) ? try decode(userFile) : ConfigFile()
        for command in user.commands ?? [] {
            if let i = merged.firstIndex(where: { $0.id == command.id }) { merged[i] = command } else { merged.append(command) }
        }
        let ids = (user.commands ?? []).map(\.id)
        if let twice = ids.first(where: { id in ids.filter { $0 == id }.count > 1 }) {
            throw ConfigError(errorDescription: "\(userFile.lastPathComponent): command id “\(twice)” is used twice")
        }
        let disabled = Set(user.disable ?? [])
        if let unknown = disabled.first(where: { id in !merged.contains { $0.id == id } }) {
            throw ConfigError(errorDescription: "\(userFile.lastPathComponent): “disable” names an unknown command “\(unknown)”")
        }
        commands = merged.filter { !disabled.contains($0.id) }
        userCommandCount = user.commands?.count ?? 0
        locale = user.locale ?? env["JEV_LOCALE"] ?? "en-US"
        minConfidence = min(max(user.minConfidence ?? 0.6, 0.3), 0.95)
        silence = min(max(user.silence ?? 0.9, 0.4), 3)
        Parse.userSites = (user.sites ?? [:]).reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        Commands.userEmoji = (user.emoji ?? [:]).map { ($0.key.lowercased(), $0.value) }
    }

    /// Creates a starter file the first time the user opens the config from the menu.
    static func createUserFileIfMissing() throws {
        guard !FileManager.default.fileExists(atPath: userFile.path) else { return }
        try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try starter.write(to: userFile, atomically: true, encoding: .utf8)
    }

    private static let starter = """
    {
      "_readme": "Jev reloads this file when you save it. Move an entry from _more_examples into commands to switch it on. Full reference: README.md in the project. Unknown keys such as this one are ignored.",

      "commands": [],

      "_more_examples": [
        { "id": "coffee_break", "title": "Break", "say": "the user is taking a break: я на перерыв, пойду за кофе, брейк",
          "do": [ { "media": "play" }, { "keys": "ctrl+cmd+q" } ] },
        { "id": "standup", "say": "open everything for the daily call: стендап, дейлик, открой всё для созвона",
          "do": [ { "open": "https://meet.google.com" }, { "wait": 1 }, { "open": "Notes" } ] },
        { "id": "next_chat", "app": "Telegram", "say": "go to the next chat in the list: следующий чат",
          "do": [ { "keys": "alt+down" } ] },
        { "id": "deploy", "say": "deploy the site to production: задеплой проект, выкати на прод",
          "do": [ { "shell": "cd ~/Projects/site && ./deploy.sh" } ] }
      ],

      "disable": [],
      "sites": { "жира": "atlassian.net" },
      "emoji": { "уточка": "🦆" }
    }

    """
}
