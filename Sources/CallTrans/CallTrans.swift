import AppKit
import AVFoundation
import Foundation

let version = "1.0.0"

let usage = """
CallTrans \(version) — 本地双向通话同传（英⇄中），全部在本机运行

用法:
  calltrans start [选项]        后台启动同传（显示字幕窗），命令立即返回
  calltrans run [选项]          前台启动同传（Ctrl-C 结束）
  calltrans stop                结束正在运行的同传，保存记录
  calltrans status              查看运行状态
  calltrans say "文本"          让运行中的同传用英语对通话方说这句话（中文会先翻译）

  calltrans setup               下载模型、申请权限（首次使用）
  calltrans doctor              检查模型 / 权限 / 虚拟麦克风
  calltrans devices             列出音频设备

  calltrans translate "文本" [--to en|zh]
  calltrans transcribe <音频文件> [--lang en-GB|zh-CN] [--translate] [--realtime]
  calltrans tts "English text" [--output 设备名|default] [--voice Daniel] [--save out.caf]
  calltrans sessions | transcript [会话ID] [--last N] | export [会话ID]

  calltrans mcp [--allow-write] MCP 服务器（stdio）

同传选项:
  --app WeChat          只采集该应用的声音（默认采集全部系统声音）
  --mic 名称            指定真实麦克风（默认：系统默认输入，自动跳过 BlackHole）
  --output 名称         对方听到的虚拟麦克风（默认：BlackHole）
  --voice 名称          英语语音（默认：最佳 en-GB 语音）  --rate 1.0
  --remote-lang en-GB   对方语言       --my-lang zh-CN 我的语言
  --no-passthrough      不把我的原声送进通话，只送英语译音
  --no-gate             关闭回声保护（对方说话时也识别我的麦克风；戴耳机时可用）
  --subtitles-only      只看字幕，不翻译我的话
  --no-overlay          不显示字幕窗    --font-size 20
"""

@main
struct CallTransMain {
    static func main() async {
        var argv = Array(CommandLine.arguments.dropFirst())
        if argv.isEmpty { print(usage); return }
        let cmd = argv.removeFirst()
        let a = Args(argv)

        switch cmd {
        case "run":
            runApp(RunConfig(a))

        case "start":
            // Detached child of the current shell: inherits the terminal's mic / screen-recording permission.
            if let s = Status.read(), s.isAlive { print("已在运行 (pid \(s.pid))"); exit(0) }
            // argv[0] is just "calltrans" when launched via $PATH, so ask the loader for our real path.
            let p = Process()
            p.executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            p.arguments = ["run"] + argv
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { print("启动失败: \(error)"); exit(1) }
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(250))
                if let s = Status.read(), s.isAlive, s.remoteSource != "-" {
                    print("已启动 (pid \(s.pid))，会话 \(s.session)")
                    print("  对方声音 ← \(s.remoteSource)\n  我的麦克风 ← \(s.micDevice)\n  对方听到 ← \(s.outputDevice ?? "（无虚拟麦克风，仅字幕）")")
                    for e in s.errors { print("⚠️ \(e)") }
                    exit(0)
                }
            }
            print("启动超时，查看日志: \(Paths.log.path)"); exit(1)

        case "stop":
            guard let s = Status.read(), s.isAlive else { print("没有在运行"); exit(0) }
            kill(s.pid, SIGTERM)
            var exited = false
            for _ in 0..<40 {   // engine's own watchdog fires at 6 s
                try? await Task.sleep(for: .milliseconds(250))
                if kill(s.pid, 0) != 0 { exited = true; break }
            }
            if !exited {
                kill(s.pid, SIGKILL)
                try? FileManager.default.removeItem(at: Paths.status)
                print("⚠️ 进程未响应，已强制结束")
            }
            let md = Paths.sessions.appendingPathComponent(s.session + ".md")
            print(FileManager.default.fileExists(atPath: md.path) ? "已结束。记录: \(md.path)"
                  : "已结束。记录（原始）: \(Paths.sessions.appendingPathComponent(s.session + ".jsonl").path)，可用 calltrans export \(s.session) 导出")

        case "status":
            guard let s = Status.read(), s.isAlive else { print("not running"); exit(1) }
            print(MCPServer.jsonString(s))

        case "say":
            let text = a.positional.joined(separator: " ")
            guard !text.isEmpty else { print("用法: calltrans say \"文本\""); exit(2) }
            guard let s = Status.read(), s.isAlive else { print("同传没有在运行"); exit(1) }
            try? Inbox.post(SayRequest(text: text, translate: !a.bool("raw")))
            print("已排队")

        case "setup":
            await runSetup(remote: a.string("remote-lang") ?? "en-GB", mine: a.string("my-lang") ?? "zh-CN")

        case "doctor":
            let c = await Doctor.checks(remote: a.string("remote-lang") ?? "en-GB", mine: a.string("my-lang") ?? "zh-CN")
            Doctor.print_(c)
            exit(c.allSatisfy(\.ok) ? 0 : 1)

        case "devices":
            for d in Devices.all() {
                print("\(d.name)\t in:\(d.inputs) out:\(d.outputs)\t\(d.uid)")
            }

        case "translate":
            let text = a.positional.joined(separator: " ")
            let toZh = a.string("to").map { $0 == "zh" } ?? !containsCJK(text)
            let tr = toZh ? Translator(from: "en", to: "zh-Hans", highFidelity: !a.bool("fast"))
                          : Translator(from: "zh-Hans", to: "en", highFidelity: !a.bool("fast"))
            do {
                let t0 = Date()
                print(try await tr.translate(text))
                if a.bool("timing") { print(String(format: "(%.0f ms)", Date().timeIntervalSince(t0) * 1000)) }
            } catch { print("翻译失败: \(error)。先运行 calltrans setup"); exit(1) }

        case "transcribe":
            guard let path = a.positional.first else { print("用法: calltrans transcribe <file>"); exit(2) }
            await transcribe(URL(fileURLWithPath: path), lang: a.string("lang") ?? "en-GB",
                             translate: a.bool("translate"), realtime: a.bool("realtime"))

        case "tts":
            await tts(a)

        case "sessions":
            for u in SessionLog.list() { print(u.deletingPathExtension().lastPathComponent, "\t", SessionLog.read(u).count, "lines") }

        case "transcript":
            guard let url = SessionLog.resolve(a.positional.first) else { print("没有记录"); exit(1) }
            let entries = SessionLog.read(url)
            for e in entries.suffix(a.int("last", entries.count)) {
                print("[\(e.dir)] \(e.src)\n    → \(e.dst)")
            }

        case "export":
            guard let url = SessionLog.resolve(a.positional.first) else { print("没有记录"); exit(1) }
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
func transcribe(_ url: URL, lang: String, translate: Bool, realtime: Bool) async {
    let asr = StreamTranscriber(locale: Locale(identifier: lang))
    let isZh = lang.hasPrefix("zh")
    let tr = isZh ? Translator(from: "zh-Hans", to: "en") : Translator(from: "en", to: "zh-Hans")
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
        print("失败: \(error)"); exit(1)
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
            print("无法写文件"); exit(1)
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
    guard let dev else { print("找不到输出设备（BlackHole 未安装？用 --output default 从扬声器播放）"); exit(1) }
    do {
        let out = try CallOutput(device: dev)
        print("playing to \(dev.name)…")
        await out.play(bufs)
        out.stop()
    } catch { print("失败: \(error)"); exit(1) }
}
