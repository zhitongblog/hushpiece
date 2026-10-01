import Foundation

// MARK: - Paths

enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("CallTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let sessions: URL = sub("sessions")
    static let inbox: URL = sub("inbox")
    static let status = root.appendingPathComponent("status.json")
    static let log = root.appendingPathComponent("calltrans.log")

    private static func sub(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Logging (stderr + file, so the GUI-launched app is debuggable)

enum Log {
    private static let queue = DispatchQueue(label: "calltrans.log")
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
    private let queue = DispatchQueue(label: "calltrans.session")
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
        var out = "# 通话记录 \(url.deletingPathExtension().lastPathComponent)\n\n"
        for e in read(url) {
            let who = e.dir == "remote" ? "对方" : (e.dir == "typed" ? "我（打字）" : "我")
            out += "**\(f.string(from: e.ts)) \(who)**  \n\(e.src)  \n> \(e.dst)\n\n"
        }
        return out
    }
}

// MARK: - Live status file (read by `calltrans status` and the MCP server)

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

    var isAlive: Bool { kill(pid, 0) == 0 }

    func write() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Paths.status, options: .atomic)
    }
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

func containsCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
}
