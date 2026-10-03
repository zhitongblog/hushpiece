import Foundation

/// Minimal MCP server over stdio (JSON-RPC 2.0, one message per line).
/// Read-only by default; `--allow-write` enables `say_in_call`.
enum MCPServer {
    static func run(allowWrite: Bool) async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String else { continue }
            let id = obj["id"]
            let params = obj["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // notification
            switch method {
            case "initialize":
                reply(id, ["protocolVersion": (params["protocolVersion"] as? String) ?? "2024-11-05",
                           "capabilities": ["tools": [:]],
                           "serverInfo": ["name": "hushpiece", "version": version]])
            case "ping":
                reply(id, [:])
            case "tools/list":
                reply(id, ["tools": tools(allowWrite: allowWrite)])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let a = params["arguments"] as? [String: Any] ?? [:]
                let (text, isError) = await call(name, a, allowWrite: allowWrite)
                reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found: \(method)"]])
            }
        }
    }

    static func tools(allowWrite: Bool) -> [[String: Any]] {
        func schema(_ props: [String: Any], _ req: [String] = []) -> [String: Any] {
            ["type": "object", "properties": props, "required": req]
        }
        var t: [[String: Any]] = [
            ["name": "status", "description": "Whether a live Hushpiece (耳语同传) translation session is running, its devices, line counts and last lines.",
             "inputSchema": schema([:])],
            ["name": "doctor", "description": "Check speech models, translation models, permissions and the virtual mic.",
             "inputSchema": schema([:])],
            ["name": "list_sessions", "description": "List recorded call transcripts (newest last).",
             "inputSchema": schema([:])],
            ["name": "get_transcript", "description": "Bilingual transcript of a call session as markdown. Defaults to the latest session.",
             "inputSchema": schema(["session": ["type": "string"], "last": ["type": "integer", "description": "only the last N lines"]])],
            ["name": "translate_text", "description": "Translate text on-device between English and Chinese (direction auto-detected unless 'to' is given).",
             "inputSchema": schema(["text": ["type": "string"], "to": ["type": "string", "enum": ["en", "zh"]]], ["text"])],
        ]
        if allowWrite {
            t.append(["name": "say_in_call", "description": "Speak a sentence to the other side of the running call in English (Chinese input is translated first).",
                      "inputSchema": schema(["text": ["type": "string"]], ["text"])])
        }
        return t
    }

    static func call(_ name: String, _ a: [String: Any], allowWrite: Bool) async -> (String, Bool) {
        switch name {
        case "status":
            guard let s = Status.read(), s.isAlive else { return ("not running", false) }
            return (jsonString(s), false)
        case "doctor":
            let c = await Doctor.checks()
            return (c.map { "\($0.ok ? "OK " : "MISSING ") \($0.name)" + ($0.ok ? "" : " -> \($0.fix)") }.joined(separator: "\n"), false)
        case "list_sessions":
            return (SessionLog.list().map { $0.deletingPathExtension().lastPathComponent }.joined(separator: "\n"), false)
        case "get_transcript":
            guard let url = SessionLog.resolve(a["session"] as? String) else { return ("no such session", true) }
            if let n = a["last"] as? Int {
                let e = SessionLog.read(url).suffix(n)
                return (e.map { "[\($0.dir)] \($0.src)\n  → \($0.dst)" }.joined(separator: "\n"), false)
            }
            return (SessionLog.markdown(url), false)
        case "translate_text":
            guard let text = a["text"] as? String else { return ("missing text", true) }
            let toZh = (a["to"] as? String).map { $0 == "zh" } ?? !containsCJK(text)
            let tr = toZh ? Translator(from: "en", to: "zh-Hans") : Translator(from: "zh-Hans", to: "en")
            do { return (try await tr.translate(text), false) } catch { return ("translation failed: \(error)", true) }
        case "say_in_call":
            guard allowWrite else { return ("say_in_call requires --allow-write", true) }
            guard let s = Status.read(), s.isAlive else { return ("no live call session running", true) }
            guard let text = a["text"] as? String else { return ("missing text", true) }
            do { try Inbox.post(SayRequest(text: text, translate: true)); return ("queued", false) }
            catch { return ("failed: \(error)", true) }
        default:
            return ("unknown tool \(name)", true)
        }
    }

    private static func reply(_ id: Any?, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id!, "result": result])
    }

    private static func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }

    static func jsonString<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
