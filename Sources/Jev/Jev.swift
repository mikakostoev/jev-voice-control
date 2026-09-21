import Foundation

/// .env values: process environment wins, then the .env inside the app bundle, then ./.env
let env: [String: String] = {
    var out: [String: String] = [:]
    let files = [Bundle.main.resourceURL?.appendingPathComponent(".env"), URL(fileURLWithPath: ".env")]
    for file in files.compactMap({ $0 }).reversed() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
    }
    return out.merging(ProcessInfo.processInfo.environment) { _, new in new }
}()

/// Appends a line to ~/Library/Logs/Jev.log — the only way to see what a menu-bar app is doing.
func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jev.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

struct Decision {
    let choice: String
    let probs: [Double]  // same order as the criteria passed to choose()
    let confidence: Double
}

struct JevError: LocalizedError {
    let errorDescription: String?
}

/// Client for the OpenRouter decisions endpoint (Jev picks among options, it does not generate text).
enum Jev {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    static func choose(state: [String: Any], instructions: String, criteria: [(String, String)]) async throws -> Decision {
        guard let key = env["OPENROUTER_API_KEY"], !key.isEmpty else {
            throw JevError(errorDescription: "OPENROUTER_API_KEY is missing in .env")
        }
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/alpha/decisions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let question: [String: Any] = [
            "type": "choice",
            "instructions": instructions,
            "criteria": Dictionary(criteria, uniquingKeysWith: { first, _ in first }),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "typesafe/jev-1.13", "state": state, "questions": ["q": question],
        ])
        var json: [String: Any]?
        var status = 0
        for attempt in 1...3 {
            let (data, response) = try await session.data(for: req)
            json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // The upstream flakes in bursts (503 "no healthy upstream", 529 overloaded, even 400 "Unknown model");
            // a retry usually goes through. Auth and billing errors won't fix themselves.
            if json?["answers"] != nil || [401, 402, 403].contains(status) || attempt == 3 { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let answer = (json?["answers"] as? [String: Any])?["q"] as? [String: Any],
              let choice = answer["choice"] as? String else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            log("jev request failed: HTTP \(status) \(message ?? "")")
            throw JevError(errorDescription: [401, 402, 403].contains(status) ? "OpenRouter rejected the API key (HTTP \(status))" : "Jev is unavailable right now — say it again")
        }
        let p = answer["probabilities"] as? [String: Any] ?? [:]
        return Decision(
            choice: choice,
            probs: criteria.map { (p[$0.0] as? NSNumber)?.doubleValue ?? 0 },
            confidence: (answer["confidence"] as? NSNumber)?.doubleValue ?? 0
        )
    }
}

/// Jev only classifies, so free-form payloads (the URL, the text to type) are cut out of the transcript here.
enum Parse {
    private static func strip(_ s: String, _ pattern: String) -> String {
        s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func text(from heard: String) -> String {
        var text = strip(heard, #"^\s*(please\s+)?(type in|type|write|enter|напиши|напечатай|введи)\s+"#)
        // "… и поставь эмодзи сердечко" inside a dictated message becomes the emoji itself
        let pattern = #"\s*(и\s+)?((поставь|добавь|вставь)\s+)?(эмодзи|смайлик|смайл|emoji)\s+(\S+)"#
        while let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              let emoji = emoji(from: String(text[r])) {
            text.replaceSubrange(r, with: " " + emoji)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func app(from heard: String) -> String {
        let s = strip(heard, #"^\s*(please\s+)?(open|launch|start|run|switch to|go to|show|открой|открыть|запусти|включи|покажи|зайди (в|на)|перейди (в|на)|переключись на)(\s+|$)"#)
        return strip(s, #"^(the|приложение)\s+|\s+(app|application)$|[.!?]+$"#).trimmingCharacters(in: .whitespaces)
    }

    /// Spoken site names (mostly Russian) that can't be turned into a domain by just appending ".com".
    static let sites: [String: String] = [
        "ютуб": "youtube.com", "ютьюб": "youtube.com", "youtube": "youtube.com",
        "гугл": "google.com", "гугл почта": "mail.google.com", "джимейл": "mail.google.com", "gmail": "mail.google.com",
        "гугл карты": "maps.google.com", "гугл диск": "drive.google.com", "гугл переводчик": "translate.google.com",
        "яндекс": "ya.ru", "яндекс почта": "mail.yandex.ru", "яндекс карты": "yandex.ru/maps",
        "яндекс музыка": "music.yandex.ru", "яндекс маркет": "market.yandex.ru", "кинопоиск": "kinopoisk.ru",
        "вк": "vk.com", "вконтакте": "vk.com", "вконтакт": "vk.com", "одноклассники": "ok.ru", "дзен": "dzen.ru",
        "твиттер": "x.com", "twitter": "x.com", "икс": "x.com", "x": "x.com",
        "телеграм": "web.telegram.org", "телеграм веб": "web.telegram.org", "telegram web": "web.telegram.org",
        "ватсап": "web.whatsapp.com", "вотсап": "web.whatsapp.com", "whatsapp": "web.whatsapp.com",
        "инстаграм": "instagram.com", "фейсбук": "facebook.com", "тикток": "tiktok.com", "тик ток": "tiktok.com",
        "линкедин": "linkedin.com", "реддит": "reddit.com", "пинтерест": "pinterest.com", "дискорд": "discord.com/app",
        "твич": "twitch.tv", "twitch": "twitch.tv", "нетфликс": "netflix.com", "спотифай": "open.spotify.com",
        "гитхаб": "github.com", "хабр": "habr.com", "стак оверфлоу": "stackoverflow.com", "stack overflow": "stackoverflow.com",
        "википедия": "ru.wikipedia.org", "wikipedia": "wikipedia.org", "вики": "ru.wikipedia.org",
        "чат джипити": "chatgpt.com", "чатгпт": "chatgpt.com", "chat gpt": "chatgpt.com",
        "клод": "claude.ai", "claude": "claude.ai", "опенроутер": "openrouter.ai", "openrouter": "openrouter.ai",
        "озон": "ozon.ru", "вайлдберриз": "wildberries.ru", "вб": "wildberries.ru", "авито": "avito.ru",
        "алиэкспресс": "aliexpress.com", "амазон": "amazon.com", "хэдхантер": "hh.ru", "хедхантер": "hh.ru", "hh": "hh.ru",
        "госуслуги": "gosuslugi.ru", "сбер": "online.sberbank.ru", "сбербанк": "online.sberbank.ru", "тинькофф": "tbank.ru", "т банк": "tbank.ru",
        "крыша": "krisha.kz", "колеса": "kolesa.kz", "каспи": "kaspi.kz", "кворк": "kwork.ru", "notion": "notion.so", "ноушен": "notion.so",
        "фигма": "figma.com", "почта": "mail.google.com", "карты": "maps.google.com", "переводчик": "translate.google.com",
    ]

    /// Extra spoken names from the user's config; they win over the built-in ones.
    static var userSites: [String: String] = [:]

    /// Dictionary names that may also be an installed app — the app wins when it exists.
    static let alsoApps: Set<String> = [
        "телеграм", "ватсап", "вотсап", "whatsapp", "дискорд", "спотифай", "notion", "ноушен", "фигма", "клод", "claude",
        "карты", "почта", "переводчик",
    ]

    private static func siteName(_ lowercased: String) -> String {
        let s = strip(lowercased, #"^\s*(please\s+)?(open|go to|launch|visit|show|открой|открыть|включи|запусти|покажи|зайди (в|на)|перейди (в|на))(\s+|$)"#)
        return strip(s, #"\s+(in|в)\s+.*$|^(the|сайт)\s+|[.!?]+$"#).trimmingCharacters(in: .whitespaces)
    }

    static func knownSite(from heard: String) -> (key: String, url: URL)? {
        let name = siteName(heard.lowercased())
        for key in [name, name.replacingOccurrences(of: " ", with: "")] {
            if let domain = userSites[key] ?? sites[key], let url = URL(string: "https://" + domain) { return (key, url) }
        }
        return nil
    }

    /// "браузер", "интернет": the user means whatever their default browser is.
    static func isBrowser(_ spoken: String) -> Bool {
        spoken.range(of: #"^(мой |my )?(браузер|browser|интернет)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What to quit: "закрой телеграм" → "телеграм", "закрой приложение" → "" (the current app).
    static func quitTarget(from heard: String) -> String {
        let s = strip(heard, #"^\s*(please\s+)?(quit|close|exit|kill|закрой|закрыть|выйди из|выключи|заверши|убей)(\s+|$)"#)
        return strip(s, #"^(the |this |это |эту |текущ\S+ )?(app|application|program|приложение|программу|программы)?\b|[.!?]+$"#)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "громкость 50" → 50, "звук на максимум" → 100, "на половину" → 50.
    static func volume(from heard: String) -> Int? {
        let s = heard.lowercased()
        if let r = s.range(of: #"\d{1,3}"#, options: .regularExpression), let n = Int(s[r]) { return min(n, 100) }
        let words: [(String, Int)] = [("максим", 100), ("полную", 100), ("полов", 50), ("средн", 50), ("миним", 10), ("четверт", 25)]
        return words.first { s.contains($0.0) }?.1
    }

    /// "открой загрузки" → ~/Downloads
    static func folder(from heard: String) -> URL? {
        let s = heard.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders: [(String, String)] = [
            ("загруз", "Downloads"), ("download", "Downloads"), ("документ", "Documents"), ("document", "Documents"),
            ("рабочий стол", "Desktop"), ("рабочем столе", "Desktop"), ("desktop", "Desktop"), ("картин", "Pictures"), ("изображен", "Pictures"),
            ("фото", "Pictures"), ("pictures", "Pictures"), ("проект", "Projects"), ("project", "Projects"), ("фильм", "Movies"), ("видео", "Movies"),
        ]
        if let hit = folders.first(where: { s.contains($0.0) }) { return home.appendingPathComponent(hit.1) }
        if s.contains("программ") || s.contains("приложени") || s.contains("applications") { return URL(fileURLWithPath: "/Applications") }
        if s.contains("домашн") || s.contains("home") { return home }
        return nil
    }

    static func emoji(from heard: String) -> String? {
        let s = heard.lowercased()
        return Commands.emoji.first { s.contains($0.0) }?.1
    }

    /// "найди на ютубе лофи" → youtube search for "лофи"; "загугли погоду" → web search for "погоду".
    static func search(from heard: String) -> URL? {
        let youtube = heard.range(of: #"(ютуб|youtube)"#, options: [.regularExpression, .caseInsensitive]) != nil
        var q = strip(heard, #"^\s*(please\s+)?(search for|search|google|find|look up|найди|найти|поищи|загугли|погугли|гугли|поиск)(\s+|$)"#)
        q = strip(q, #"(^|\s)(в|на|in|on)\s+(гугле|google|интернете|ютубе|ютьюбе|youtube)(\s|$)"#)
        q = strip(q, #"[.!?]+$"#).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        var c = URLComponents(string: youtube ? "https://www.youtube.com/results" : "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: youtube ? "search_query" : "q", value: q)]
        return c.url
    }

    /// Only a domain actually spoken ("x.com", "github dot com"), no guessing.
    static func explicitURL(from heard: String) -> URL? {
        let s = heard.lowercased().replacingOccurrences(of: " dot ", with: ".")
        guard let r = s.range(of: #"[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?"#, options: .regularExpression) else { return nil }
        return URL(string: "https://" + s[r])
    }

    static func url(from heard: String) -> URL? {
        let s = heard.lowercased()
        if let url = explicitURL(from: heard) { return url }
        if let known = knownSite(from: heard) { return known.url }
        let site = siteName(s).replacingOccurrences(of: " ", with: "")
        guard !site.isEmpty, site.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://\(site).com")
    }
}
