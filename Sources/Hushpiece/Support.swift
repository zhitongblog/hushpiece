import Foundation

// MARK: - Paths

enum Paths {
    static let root: URL = {
        // HUSHPIECE_HOME lets tests run against a scratch directory instead of the user's records.
        if let home = ProcessInfo.processInfo.environment["HUSHPIECE_HOME"], !home.isEmpty {
            let url = URL(fileURLWithPath: home, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Hushpiece", isDirectory: true)
        // Carry over transcripts from the CallTrans prototype.
        let old = base.appendingPathComponent("CallTrans", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
            try? FileManager.default.removeItem(at: url.appendingPathComponent("status.json"))
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let sessions: URL = sub("sessions")
    static let inbox: URL = sub("inbox")
    static let control: URL = sub("control")
    static let status = root.appendingPathComponent("status.json")
    static let appLock = root.appendingPathComponent("app.pid")
    static let log = root.appendingPathComponent("hushpiece.log")

    private static func sub(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Logging (stderr + file, so the GUI-launched app is debuggable)

enum Log {
    private static let queue = DispatchQueue(label: "hushpiece.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ msg: String) {
        let line = "[\(fmt.string(from: Date()))] \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        queue.async {
            if let h = try? FileHandle(forWritingTo: Paths.log) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: Paths.log)
            }
        }
    }
}

// MARK: - Arguments

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    flags[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    flags[key] = argv[i + 1]; i += 1
                } else {
                    flags[key] = "true"
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func string(_ k: String) -> String? { flags[k] }
    func bool(_ k: String) -> Bool { flags[k] == "true" || flags[k] == "1" || flags[k] == "yes" }
    func double(_ k: String, _ d: Double) -> Double { flags[k].flatMap(Double.init) ?? d }
    func int(_ k: String, _ d: Int) -> Int { flags[k].flatMap(Int.init) ?? d }
}

// MARK: - Session transcript (JSONL)

struct Entry: Codable {
    var ts: Date
    var dir: String      // "remote" (they said, en→zh) | "me" (I said, zh→en) | "typed"
    var src: String
    var dst: String
}

final class SessionLog {
    let url: URL
    let id: String
    private let queue = DispatchQueue(label: "hushpiece.session")
    private let enc: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    init() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
        id = f.string(from: Date())
        url = Paths.sessions.appendingPathComponent("\(id).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func append(_ e: Entry) {
        queue.async {
            guard var data = try? self.enc.encode(e), let h = try? FileHandle(forWritingTo: self.url) else { return }
            data.append(0x0A)
            h.seekToEndOfFile(); h.write(data); try? h.close()
        }
    }

    static func list() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func resolve(_ id: String?) -> URL? {
        guard let id else { return list().last }
        return list().first { $0.deletingPathExtension().lastPathComponent == id || $0.lastPathComponent == id }
    }

    static func read(_ url: URL) -> [Entry] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
    }

    static func markdown(_ url: URL) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        var out = L("# 会议记录 ", "# Meeting transcript ") + "\(url.deletingPathExtension().lastPathComponent)\n\n"
        for e in read(url) {
            let who = e.dir == "remote" ? L("对方", "Them") : (e.dir == "typed" ? L("我（打字）", "Me (typed)") : L("我", "Me"))
            out += "**\(f.string(from: e.ts)) \(who)**  \n\(e.src)  \n> \(e.dst)\n\n"
        }
        return out
    }
}

// MARK: - Live status file (read by `hushpiece status` and the MCP server)

struct Status: Codable {
    var pid: Int32
    var session: String
    var started: Date
    var updated: Date
    var remoteSource: String
    var micDevice: String
    var outputDevice: String?
    var translateMe: Bool
    var remoteLines: Int
    var meLines: Int
    var lastRemote: String?
    var lastMe: String?
    var errors: [String]

    static func read() -> Status? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: Paths.status), let s = try? dec.decode(Status.self, from: d) else { return nil }
        return s
    }

    var isAlive: Bool { processAlive(pid) }

    func write() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Paths.status, options: .atomic)
    }
}

/// kill(pid, 0) answers EPERM instead of 0 inside the App Sandbox, which may not signal other
/// processes — that still means the process exists.
func processAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

// MARK: - App instance lock + control channel (CLI `start` / `stop` talk to the running app)

/// The process that owns the menu bar item. One per user; sessions start and stop inside it.
enum AppInstance {
    static func runningPID() -> pid_t? {
        guard let s = try? String(contentsOf: Paths.appLock, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid != getpid(),
              processAlive(pid) else { return nil }
        return pid
    }
    static func claim() { try? "\(getpid())".write(to: Paths.appLock, atomically: true, encoding: .utf8) }
    static func release() {
        if (try? String(contentsOf: Paths.appLock, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "\(getpid())" {
            try? FileManager.default.removeItem(at: Paths.appLock)
        }
    }
}

struct ControlRequest: Codable {
    var cmd: String              // "start" | "stop" | "show" | "quit"
    var args: [String] = []      // CLI flags for "start" (same as `hushpiece run`)
}

enum Control {
    static func post(_ r: ControlRequest) throws {
        let url = Paths.control.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
        try JSONEncoder().encode(r).write(to: url, options: .atomic)
    }
    static func drain() -> [ControlRequest] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Paths.control, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { url in
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ControlRequest.self, from: $0) }
        }
    }
}

// MARK: - Languages

/// A language the whole pipeline supports: on-device speech recognition + translation + a voice.
struct Lang: Hashable, Identifiable {
    let id: String      // speech locale, e.g. "en-GB"
    let zh: String      // "英语（英国）"
    let en: String      // "English (UK)"
    let zhShort: String // tight places: "英"
    let enShort: String // "EN"

    var name: String { L(zh, en) }
    var short: String { L(zhShort, enShort) }
    /// The language without the region, for sentences like "用英语念给对方听" / "spoken in English".
    var plain: String { L(zh.components(separatedBy: "（").first ?? zh, en.components(separatedBy: " (").first ?? en) }

    static let all: [Lang] = [
        Lang(id: "zh-CN", zh: "中文（普通话）", en: "Chinese (Mandarin)", zhShort: "中", enShort: "ZH"),
        Lang(id: "zh-TW", zh: "中文（台湾）", en: "Chinese (Taiwan)", zhShort: "中", enShort: "ZH"),
        Lang(id: "en-GB", zh: "英语（英国）", en: "English (UK)", zhShort: "英", enShort: "EN"),
        Lang(id: "en-US", zh: "英语（美国）", en: "English (US)", zhShort: "英", enShort: "EN"),
        Lang(id: "en-AU", zh: "英语（澳大利亚）", en: "English (Australia)", zhShort: "英", enShort: "EN"),
        Lang(id: "en-IN", zh: "英语（印度）", en: "English (India)", zhShort: "英", enShort: "EN"),
        Lang(id: "ja-JP", zh: "日语", en: "Japanese", zhShort: "日", enShort: "JA"),
        Lang(id: "ko-KR", zh: "韩语", en: "Korean", zhShort: "韩", enShort: "KO"),
        Lang(id: "fr-FR", zh: "法语", en: "French", zhShort: "法", enShort: "FR"),
        Lang(id: "de-DE", zh: "德语", en: "German", zhShort: "德", enShort: "DE"),
        Lang(id: "es-ES", zh: "西班牙语（西班牙）", en: "Spanish (Spain)", zhShort: "西", enShort: "ES"),
        Lang(id: "es-MX", zh: "西班牙语（墨西哥）", en: "Spanish (Mexico)", zhShort: "西", enShort: "ES"),
        Lang(id: "it-IT", zh: "意大利语", en: "Italian", zhShort: "意", enShort: "IT"),
        Lang(id: "pt-BR", zh: "葡萄牙语（巴西）", en: "Portuguese (Brazil)", zhShort: "葡", enShort: "PT"),
        Lang(id: "pt-PT", zh: "葡萄牙语（葡萄牙）", en: "Portuguese (Portugal)", zhShort: "葡", enShort: "PT"),
    ]
    static func of(_ id: String) -> Lang {
        all.first { $0.id == id } ?? all.first { $0.id.prefix(2) == id.prefix(2) }
            ?? Lang(id: id, zh: id, en: id, zhShort: id, enShort: id)
    }

    /// First-run defaults: "I speak" follows the Mac's language; the other side is English for
    /// Chinese speakers and Chinese for everyone else (the app's two founding use cases).
    static var defaultMine: String {
        for pref in Locale.preferredLanguages {
            let p = pref.replacingOccurrences(of: "_", with: "-")
            if p.hasPrefix("zh-Hant") || p.hasPrefix("zh-TW") || p.hasPrefix("zh-HK") { return "zh-TW" }
            if p.hasPrefix("zh") { return "zh-CN" }
            if let exact = all.first(where: { p.hasPrefix($0.id) }) { return exact.id }
            if let same = all.first(where: { $0.id.prefix(2) == p.prefix(2) }) { return same.id }
        }
        return "en-US"
    }
    static var defaultRemote: String { defaultMine.hasPrefix("zh") ? "en-GB" : "zh-CN" }
}

// MARK: - Interface language

/// The app speaks Chinese to Chinese-language Macs and English to everyone else, unless the user
/// picked one in Settings. HUSHPIECE_UILANG=zh|en overrides both (tests, screenshots).
enum UILang {
    static let isZh: Bool = {
        switch ProcessInfo.processInfo.environment["HUSHPIECE_UILANG"] ?? Prefs.shared.uiLanguage {
        case "zh": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }()
}

/// Inline bilingual string: every user-facing text in the app is written as L("中文", "English").
@inline(__always) func L(_ zh: String, _ en: String) -> String { UILang.isZh ? zh : en }

// MARK: - User settings (menu bar / settings window; CLI flags override per run)

final class Prefs {
    static let shared = Prefs()
    /// Inside the app bundle (Finder launch, or the CLI symlinked to the bundle's binary) the
    /// standard defaults *are* app.hushpiece.Hushpiece — and AppKit's window-frame autosave
    /// writes there too. A suite named after our own bundle ID is the one thing NSUserDefaults
    /// refuses to honour, so only use the suite when running unbundled (swift run / tests).
    private let d: UserDefaults = Bundle.main.bundleIdentifier == "app.hushpiece.Hushpiece"
        ? .standard : (UserDefaults(suiteName: "app.hushpiece.Hushpiece") ?? .standard)

    var myLang: String { get { d.string(forKey: "myLang") ?? Lang.defaultMine } set { d.set(newValue, forKey: "myLang") } }
    var remoteLang: String { get { d.string(forKey: "remoteLang") ?? Lang.defaultRemote } set { d.set(newValue, forKey: "remoteLang") } }
    /// Interface language: "auto" (follow macOS), "zh", "en". Takes effect on the next launch.
    var uiLanguage: String { get { d.string(forKey: "uiLanguage") ?? "auto" } set { d.set(newValue, forKey: "uiLanguage") } }
    var remoteApp: String? { get { d.string(forKey: "remoteApp") } set { d.set(newValue, forKey: "remoteApp") } }
    var micName: String? { get { d.string(forKey: "micName") } set { d.set(newValue, forKey: "micName") } }
    var outputName: String? { get { d.string(forKey: "outputName") } set { d.set(newValue, forKey: "outputName") } }
    var voiceName: String? { get { d.string(forKey: "voiceName") } set { d.set(newValue, forKey: "voiceName") } }
    var rate: Double { get { d.object(forKey: "rate") as? Double ?? 1.0 } set { d.set(newValue, forKey: "rate") } }
    var passthrough: Bool { get { d.object(forKey: "passthrough") as? Bool ?? true } set { d.set(newValue, forKey: "passthrough") } }
    /// "auto" (on unless headphones are the output), "on", "off"
    var echoGuard: String { get { d.string(forKey: "echoGuard") ?? "auto" } set { d.set(newValue, forKey: "echoGuard") } }
    var translateMe: Bool { get { d.object(forKey: "translateMe") as? Bool ?? true } set { d.set(newValue, forKey: "translateMe") } }
    /// Only speak into the call when a meeting app is actually reading the virtual mic.
    var speakOnlyWhenListened: Bool { get { d.object(forKey: "speakOnlyWhenListened") as? Bool ?? true } set { d.set(newValue, forKey: "speakOnlyWhenListened") } }
    var fontSize: Double { get { d.object(forKey: "fontSize") as? Double ?? 20 } set { d.set(newValue, forKey: "fontSize") } }
    var compact: Bool { get { d.bool(forKey: "compact") } set { d.set(newValue, forKey: "compact") } }
    var opacity: Double { get { d.object(forKey: "opacity") as? Double ?? 0.94 } set { d.set(newValue, forKey: "opacity") } }
    var onboarded: Bool { get { d.bool(forKey: "onboarded") } set { d.set(newValue, forKey: "onboarded") } }
    /// Subtitle panel frame (NSStringFromRect). Kept here rather than in AppKit's frame autosave,
    /// which writes to whatever the process's standard defaults are — a different domain when the
    /// CLI symlink launches the app than when Finder does.
    var overlayFrame: String? { get { d.string(forKey: "overlayFrame") } set { d.set(newValue, forKey: "overlayFrame") } }
}

// MARK: - Inbox: other processes (CLI `say`, MCP) ask the running instance to speak

struct SayRequest: Codable { var text: String; var translate: Bool }

enum Inbox {
    static func post(_ r: SayRequest) throws {
        let url = Paths.inbox.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
        try JSONEncoder().encode(r).write(to: url, options: .atomic)
    }

    static func drain() -> [SayRequest] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Paths.inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { url in
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SayRequest.self, from: $0) }
        }
    }
}

/// True if the text has at least one letter / CJK character (drops ", , , ," style noise).
func isMeaningful(_ s: String) -> Bool {
    s.unicodeScalars.contains { CharacterSet.letters.contains($0) }
}

/// The recognizer writes "first" as "1st" ("the figures 1st and then…"), which the translator
/// reads as "No. 1". Spell ordinals out unless they look like a date.
func normalizeEnglish(_ s: String) -> String {
    var out = s
    for (n, w) in [("1st", "first"), ("2nd", "second"), ("3rd", "third")] {
        out = out.replacingOccurrences(of: "\\b\(n)\\b(?=\\s*(and|then|of all|,|\\.|;|$))",
                                       with: w, options: .regularExpression)
    }
    return out
}

/// Translation-framework language code for a speech locale: zh-CN → zh-Hans, zh-TW/HK → zh-TW,
/// yue-CN → zh-Hans, ja-JP → ja, en-GB → en.
func translationLang(_ locale: String) -> String {
    let l = locale.replacingOccurrences(of: "_", with: "-")
    if l.hasPrefix("zh-TW") || l.hasPrefix("zh-HK") { return "zh-TW" }
    if l.hasPrefix("zh") || l.hasPrefix("yue") { return "zh-Hans" }
    return String(l.prefix(while: { $0 != "-" }))
}

/// Default partner language: Chinese speakers talk to English speakers and vice versa.
func defaultPartner(_ lang: String) -> String { lang.hasPrefix("zh") ? "en" : "zh-Hans" }

/// Does the text contain characters of the script this language is written in?
/// Used to drop recognizer noise ("you", ", , ,") that can't belong to the expected language.
func matchesScript(_ s: String, lang: String) -> Bool {
    let l = translationLang(lang)
    return s.unicodeScalars.contains { c in
        let v = c.value
        switch l {
        case "zh-Hans", "zh-TW": return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
        case "ja": return (0x3040...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v)
        case "ko": return (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v)
        default: return c.properties.isAlphabetic && v < 0x0250   // Latin incl. accents
        }
    }
}

func containsCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
}
