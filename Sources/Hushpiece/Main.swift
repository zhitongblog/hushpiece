import AppKit
import AVFoundation
import Foundation

let version = "1.1.0"

let usageZh = """
耳语同传 Hushpiece \(version) — 本机双向会议同传，识别、翻译、发音都在这台 Mac 上完成

用法:
  hushpiece app                 打开菜单栏 App（和双击“耳语同传.app”一样）
  hushpiece start [选项]        开始同传（App 在运行时交给它；否则后台启动），命令立即返回
  hushpiece run [选项]          前台运行一次同传，结束即退出（Ctrl-C 结束）
  hushpiece stop                结束同传，保存记录
  hushpiece status              查看运行状态
  hushpiece say "文本"          让对方听到这句话（不是对方语言的会先翻译）

  hushpiece setup               打开使用引导（选语言、下载模型、授权）
  hushpiece doctor              检查模型 / 权限 / 虚拟麦克风
  hushpiece devices             列出音频设备
  hushpiece langs               列出支持的语言

  hushpiece translate "文本" [--from zh] [--to en]
  hushpiece transcribe <音频文件> [--lang en-GB] [--translate] [--to zh] [--realtime]
  hushpiece tts "文本" [--lang en-GB] [--output 设备名|default] [--voice Daniel] [--save out.caf]
  hushpiece sessions | transcript [会话ID] [--last N] | export [会话ID]

  hushpiece mcp [--allow-write] MCP 服务器（stdio）

同传选项（不写就用 App 设置里的值）:
  --remote-lang en-GB   对方语言       --my-lang zh-CN 我的语言
  --app 企业微信        只采集该应用的声音（默认采集全部系统声音）
  --mic 名称            指定真实麦克风（默认：系统默认输入，跳过虚拟麦克风）
  --output 名称         对方听到的虚拟麦克风（默认：自动）
  --voice 名称          译文语音   --rate 1.0
  --no-passthrough      不把我的原声送进通话，只送译文语音
  --echo-guard auto|on|off   回声保护（默认 auto：外放开、耳机关）；--no-gate 等于 off
  --always-speak        会议软件没在用虚拟麦克风时也播报译文
  --subtitles-only      只看字幕，不翻译我的话
  --no-overlay          不显示字幕窗    --font-size 20
"""

let usageEn = """
Hushpiece \(version) — two-way meeting interpreter that runs entirely on this Mac

Usage:
  hushpiece app                 open the menu bar app (same as double-clicking it)
  hushpiece start [options]     start interpreting (handed to the app if it's running), returns at once
  hushpiece run [options]       interpret in the foreground, exit when it ends (Ctrl-C to end)
  hushpiece stop                end interpreting and save the transcript
  hushpiece status              show what is running
  hushpiece say "text"          say this to the other side (translated first unless already in their language)

  hushpiece setup               open the setup guide (languages, models, permissions)
  hushpiece doctor              check models / permissions / virtual microphone
  hushpiece devices             list audio devices
  hushpiece langs               list supported languages

  hushpiece translate "text" [--from zh] [--to en]
  hushpiece transcribe <audio file> [--lang en-GB] [--translate] [--to zh] [--realtime]
  hushpiece tts "text" [--lang en-GB] [--output device|default] [--voice Daniel] [--save out.caf]
  hushpiece sessions | transcript [id] [--last N] | export [id]

  hushpiece mcp [--allow-write] MCP server (stdio)

Interpreting options (default: the app's settings):
  --remote-lang en-GB   their language      --my-lang zh-CN   my language
  --app Zoom            only capture this app's audio (default: all system audio)
  --mic name            real microphone (default: system input, skipping virtual devices)
  --output name         virtual microphone the other side hears (default: automatic)
  --voice name          translation voice   --rate 1.0
  --no-passthrough      don't send my own voice, only the spoken translation
  --echo-guard auto|on|off   pause my recognition while they talk (auto: on with speakers); --no-gate = off
  --always-speak        speak translations even when no meeting app uses the virtual microphone
  --subtitles-only      subtitles only, don't translate me
  --no-overlay          no subtitle panel    --font-size 20
"""

var usage: String { L(usageZh, usageEn) }

@main
struct HushpieceMain {
    static func main() async {
        var argv = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        // Launched from Finder / Login Items / `open`: the menu bar app.
        if argv.isEmpty {
            if Bundle.main.bundleURL.pathExtension == "app" {
                await runAppMode(start: nil, quitWhenSessionEnds: false, showOnboarding: !Prefs.shared.onboarded)
            }
            print(usage); return
        }
        let cmd = argv.removeFirst()
        let a = Args(argv)

        switch cmd {
        case "app":
            await runAppMode(start: nil, quitWhenSessionEnds: false, showOnboarding: a.bool("onboarding") || !Prefs.shared.onboarded)

        case "run":
            if let pid = AppInstance.runningPID() {
                print(L("耳语同传 App 正在运行 (pid \(pid))，请用 hushpiece start", "The Hushpiece app is running (pid \(pid)); use hushpiece start")); exit(1)
            }
            await runAppMode(start: RunConfig(a), quitWhenSessionEnds: true, showOnboarding: false)

        case "start":
            if let s = Status.read(), s.isAlive { print(L("已在运行 (pid \(s.pid))", "Already running (pid \(s.pid))")); exit(0) }
            if AppInstance.runningPID() != nil {
                try? Control.post(ControlRequest(cmd: "start", args: argv))
            } else {
                // Detached child of the current shell: inherits the terminal's mic / screen-recording permission.
                // argv[0] is just "hushpiece" when launched via $PATH, so ask the loader for our real path.
                let p = Process()
                p.executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
                p.arguments = ["run"] + argv
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { print(L("启动失败：", "Failed to start: ") + "\(error)"); exit(1) }
            }
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(250))
                if let s = Status.read(), s.isAlive, s.remoteSource != "-" {
                    print(L("已启动 (pid \(s.pid))，会话 \(s.session)", "Started (pid \(s.pid)), session \(s.session)"))
                    print(L("  对方声音 ← ", "  their audio ← ") + s.remoteSource + L("\n  我的麦克风 ← ", "\n  my microphone ← ") + s.micDevice + L("\n  对方听到 ← ", "\n  they hear ← ") + (s.outputDevice ?? L("（无虚拟麦克风，仅字幕）", "(no virtual microphone, subtitles only)")))
                    for e in s.errors { print("⚠️ \(e)") }
                    exit(0)
                }
            }
            print(L("启动超时，查看日志：", "Timed out starting; see the log: ") + Paths.log.path); exit(1)

        case "stop":
            guard let s = Status.read(), s.isAlive else { print(L("没有在运行", "Not running")); exit(0) }
            // Ask the owning process to end the session (the menu bar app keeps running).
            try? Control.post(ControlRequest(cmd: "stop"))
            var ended = false
            for _ in 0..<40 {   // engine's own watchdog fires at 6 s
                try? await Task.sleep(for: .milliseconds(250))
                if Status.read() == nil || !processAlive(s.pid) { ended = true; break }
            }
            if !ended {
                kill(s.pid, SIGKILL)
                try? FileManager.default.removeItem(at: Paths.status)
                print(L("⚠️ 进程未响应，已强制结束", "⚠️ The process didn't respond and was killed"))
            }
            let md = Paths.sessions.appendingPathComponent(s.session + ".md")
            print(FileManager.default.fileExists(atPath: md.path) ? L("已结束。记录：", "Ended. Transcript: ") + md.path
                  : L("已结束。记录（原始）：", "Ended. Raw transcript: ") + Paths.sessions.appendingPathComponent(s.session + ".jsonl").path
                    + L("，可用 hushpiece export \(s.session) 导出", " (hushpiece export \(s.session) to export)"))

        case "status":
            guard let s = Status.read(), s.isAlive else { print("not running"); exit(1) }
            print(MCPServer.jsonString(s))

        case "say":
            let text = a.positional.joined(separator: " ")
            guard !text.isEmpty else { print(L("用法：hushpiece say \"文本\"", "Usage: hushpiece say \"text\"")); exit(2) }
            guard let s = Status.read(), s.isAlive else { print(L("同传没有在运行", "Not interpreting")); exit(1) }
            try? Inbox.post(SayRequest(text: text, translate: !a.bool("raw")))
            print(L("已排队", "Queued"))

        case "setup":
            if AppInstance.runningPID() != nil { try? Control.post(ControlRequest(cmd: "onboarding")); print(L("已在耳语同传中打开使用引导", "Opened the setup guide in Hushpiece")); exit(0) }
            await runAppMode(start: nil, quitWhenSessionEnds: false, showOnboarding: true)

        case "prefs":   // diagnostics: which defaults domain this process reads
            print("bundle:", Bundle.main.bundleIdentifier ?? "nil", Bundle.main.bundlePath)
            print("onboarded:", Prefs.shared.onboarded, " myLang:", Prefs.shared.myLang, " remoteLang:", Prefs.shared.remoteLang, " fontSize:", Prefs.shared.fontSize)

        case "langs":
            for l in Lang.all { print("\(l.id)\t\(l.name)") }

        case "doctor":
            let c = await Doctor.checks(remote: a.string("remote-lang") ?? Prefs.shared.remoteLang, mine: a.string("my-lang") ?? Prefs.shared.myLang)
            Doctor.print_(c)
            exit(c.allSatisfy(\.ok) ? 0 : 1)

        case "devices":
            for d in Devices.all() {
                print("\(d.name)\t in:\(d.inputs) out:\(d.outputs)\t\(d.uid)")
            }

        case "translate":
            let text = a.positional.joined(separator: " ")
            // --from / --to take any language the Translation framework supports (en, zh, ja, ko, fr, …).
            let norm = { (s: String) in s == "zh" ? "zh-Hans" : s }
            let from = a.string("from").map(norm) ?? (containsCJK(text) ? "zh-Hans" : "en")
            let to = a.string("to").map(norm) ?? defaultPartner(from)
            let tr = Translator(from: from, to: to, highFidelity: !a.bool("fast"))
            do {
                let t0 = Date()
                print(try await tr.translate(text))
                if a.bool("timing") { print(String(format: "(%.0f ms)", Date().timeIntervalSince(t0) * 1000)) }
            } catch { print(L("翻译失败：", "Translation failed: ") + "\(error)" + L("。先运行 hushpiece setup", ". Run hushpiece setup first")); exit(1) }

        case "transcribe":
            guard let path = a.positional.first else { print(L("用法：hushpiece transcribe <文件>", "Usage: hushpiece transcribe <file>")); exit(2) }
            await transcribe(URL(fileURLWithPath: path), lang: a.string("lang") ?? "en-GB",
                             translate: a.bool("translate"), realtime: a.bool("realtime"),
                             target: a.string("to").map { $0 == "zh" ? "zh-Hans" : $0 })

        case "tts":
            await tts(a)

        case "sessions":
            for u in SessionLog.list() { print(u.deletingPathExtension().lastPathComponent, "\t", SessionLog.read(u).count, "lines") }

        case "transcript":
            guard let url = SessionLog.resolve(a.positional.first) else { print(L("没有记录", "No transcripts")); exit(1) }
            let entries = SessionLog.read(url)
            for e in entries.suffix(a.int("last", entries.count)) {
                print("[\(e.dir)] \(e.src)\n    → \(e.dst)")
            }

        case "export":
            guard let url = SessionLog.resolve(a.positional.first) else { print(L("没有记录", "No transcripts")); exit(1) }
            print(SessionLog.markdown(url))

        case "mcp":
            await MCPServer.run(allowWrite: a.bool("allow-write"))

        case "version", "--version", "-v":
            print(version)

        default:
            print(usage)
        }
        exit(0)
    }
}

/// Streams a file through the same recognizer (and translator) the live call uses.
func transcribe(_ url: URL, lang: String, translate: Bool, realtime: Bool, target: String? = nil) async {
    let asr = StreamTranscriber(locale: Locale(identifier: lang))
    let src = translationLang(lang)
    let tr = Translator(from: src, to: target ?? defaultPartner(src))
    let t0 = Date()
    let printer = AsyncStream<String>.makeStream()
    asr.onFinal = { printer.continuation.yield($0) }
    let consumer = Task {
        for await text in printer.stream {
            let at = String(format: "%5.1fs", Date().timeIntervalSince(t0))
            if translate {
                let out = (try? await tr.translate(text)) ?? "(translation failed)"
                print("\(at)  \(text)\n        → \(out)")
            } else {
                print("\(at)  \(text)")
            }
        }
    }
    do {
        try await asr.start()
        try FileSource.stream(url, realtime: realtime) { asr.feed($0) }
        await asr.finish()
    } catch {
        print(L("失败：", "Failed: ") + "\(error)"); exit(1)
    }
    printer.continuation.finish()
    await consumer.value
}

func tts(_ a: Args) async {
    let text = a.positional.joined(separator: " ")
    let voice = Voice(language: a.string("lang") ?? "en-GB", name: a.string("voice"), rate: a.double("rate", 1.0))
    print("voice: \(voice.voice?.name ?? "?") (\(voice.voice?.language ?? "?"))")
    let bufs = await voice.render(text)
    if let save = a.string("save") {
        guard let first = bufs.first, let f = try? AVAudioFile(forWriting: URL(fileURLWithPath: save), settings: first.format.settings) else {
            print(L("无法写文件", "Can't write the file")); exit(1)
        }
        for b in bufs { try? f.write(from: b) }
        print("saved \(save)")
        return
    }
    let name = a.string("output")
    let dev: AudioDevice?
    if name == "default" {
        let id = Devices.defaultDevice(input: false)
        dev = Devices.all().first { $0.id == id }
    } else {
        dev = name.flatMap { Devices.find($0, output: true) } ?? Devices.blackHole()
    }
    guard let dev else { print(L("找不到输出设备（没有虚拟麦克风？用 --output default 从扬声器播放）", "No output device (no virtual microphone? use --output default to play on the speakers)")); exit(1) }
    do {
        let out = try CallOutput(device: dev)
        print("playing to \(dev.name)…")
        await out.play(bufs)
        out.stop()
    } catch { print(L("失败：", "Failed: ") + "\(error)"); exit(1) }
}
