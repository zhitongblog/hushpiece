import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor final class SettingsModel: ObservableObject {
    private let p = Prefs.shared
    @Published var myLang: String { didSet { p.myLang = myLang } }
    @Published var remoteLang: String { didSet { p.remoteLang = remoteLang; if !voices.contains(where: { $0.name == voiceName }) { voiceName = "" } } }
    @Published var remoteApp: String { didSet { p.remoteApp = remoteApp.isEmpty ? nil : remoteApp } }
    @Published var micName: String { didSet { p.micName = micName.isEmpty ? nil : micName } }
    @Published var outputName: String { didSet { p.outputName = outputName.isEmpty ? nil : outputName } }
    @Published var voiceName: String { didSet { p.voiceName = voiceName.isEmpty ? nil : voiceName } }
    @Published var rate: Double { didSet { p.rate = rate } }
    @Published var passthrough: Bool { didSet { p.passthrough = passthrough } }
    @Published var echoGuard: String { didSet { p.echoGuard = echoGuard } }
    @Published var speakOnlyWhenListened: Bool { didSet { p.speakOnlyWhenListened = speakOnlyWhenListened } }
    @Published var launchAtLogin: Bool { didSet { setLaunchAtLogin(launchAtLogin) } }
    @Published var uiLanguage: String { didSet { p.uiLanguage = uiLanguage } }
    @Published var loginError = ""
    private let synth = AVSpeechSynthesizer()

    init() {
        myLang = p.myLang; remoteLang = p.remoteLang; remoteApp = p.remoteApp ?? ""
        micName = p.micName ?? ""; outputName = p.outputName ?? ""; voiceName = p.voiceName ?? ""
        rate = p.rate; passthrough = p.passthrough; echoGuard = p.echoGuard
        speakOnlyWhenListened = p.speakOnlyWhenListened
        launchAtLogin = SMAppService.mainApp.status == .enabled
        uiLanguage = p.uiLanguage
    }

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    /// The language this process is actually showing (fixed at launch).
    let launchedUILanguage = Prefs.shared.uiLanguage
    var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language == remoteLang || $0.language.prefix(2) == remoteLang.prefix(2) }
            .sorted { ($0.language == remoteLang ? 0 : 1, -$0.quality.rawValue, $0.name) < ($1.language == remoteLang ? 0 : 1, -$1.quality.rawValue, $1.name) }
    }

    func preview() {
        let u = AVSpeechUtterance(string: OnboardingModel.samples[translationLang(remoteLang)] ?? "Hello")
        u.voice = Voice(language: remoteLang, name: voiceName.isEmpty ? nil : voiceName, rate: rate).voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch { loginError = error.localizedDescription }
    }
}

struct SettingsView: View {
    @ObservedObject var overlay: OverlayModel
    @StateObject private var s = SettingsModel()

    var body: some View {
        TabView {
            general.tabItem { Label(L("通用", "General"), systemImage: "gearshape") }
            audio.tabItem { Label(L("语言与声音", "Languages & Audio"), systemImage: "waveform") }
            subtitles.tabItem { Label(L("字幕", "Subtitles"), systemImage: "captions.bubble") }
            records.tabItem { Label(L("会议记录", "Transcripts"), systemImage: "doc.text") }
            advanced.tabItem { Label(L("高级", "Advanced"), systemImage: "terminal") }
        }
        .padding(20)
        .frame(width: 640, height: 540)
    }

    private var general: some View {
        Form {
            HStack(spacing: 14) {
                BrandMark(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("耳语同传 Hushpiece", "Hushpiece 耳语同传")).font(.system(size: 16, weight: .semibold))
                    Text(L("版本 \(version) · 识别、翻译、发音都在本机完成", "Version \(version) · recognition, translation and speech all on this Mac")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)
            if s.isBundled {
                Toggle(L("登录时启动（只在菜单栏，不自动开始同传）", "Open at login (menu bar only; doesn't start interpreting)"), isOn: $s.launchAtLogin)
                if !s.loginError.isEmpty { Text(s.loginError).font(.caption).foregroundStyle(.orange) }
            }
            Toggle(L("只在会议软件使用虚拟麦克风时播报译文", "Only speak translations while a meeting app is using the virtual microphone"), isOn: $s.speakOnlyWhenListened)
            Text(L("避免没进会议时，把身边的说话声也翻译并播出去。", "So that talk around you isn't translated and spoken before you've joined a meeting.")).font(.caption).foregroundStyle(.secondary)
            Picker(L("界面语言", "Interface language"), selection: $s.uiLanguage) {
                Text(L("跟随系统", "Same as macOS")).tag("auto")
                Text("中文").tag("zh")
                Text("English").tag("en")
            }
            if s.uiLanguage != s.launchedUILanguage {
                HStack {
                    Text(L("重新打开耳语同传后生效", "Takes effect when Hushpiece reopens")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if s.isBundled { Button(L("立即重新打开", "Reopen Now")) { AppController.shared?.relaunch() } }
                }
            }
            Button(L("重新打开使用引导…", "Open Setup Guide…")) { AppController.shared?.showOnboardingWindow() }
        }
        .formStyle(.grouped)
    }

    private var audio: some View {
        Form {
            Section(L("语言（下次开始同传时生效）", "Languages (apply next time you start)")) {
                Picker(L("我说", "I speak"), selection: $s.myLang) { ForEach(Lang.all) { Text($0.name).tag($0.id) } }
                Picker(L("对方说", "They speak"), selection: $s.remoteLang) { ForEach(Lang.all) { Text($0.name).tag($0.id) } }
            }
            Section(L("声音", "Audio")) {
                Picker(L("只听这个软件", "Listen to"), selection: $s.remoteApp) {
                    Text(L("全部系统声音", "All system audio")).tag("")
                    ForEach(runningApps(), id: \.self) { Text($0).tag($0) }
                }
                Picker(L("我的麦克风", "My microphone"), selection: $s.micName) {
                    Text(L("自动（系统默认，跳过虚拟麦克风）", "Automatic (system default, skipping virtual devices)")).tag("")
                    ForEach(Devices.inputs(), id: \.uid) { Text($0.name).tag($0.name) }
                }
                Picker(L("译文送到", "Send translation to"), selection: $s.outputName) {
                    Text(L("自动（虚拟麦克风）", "Automatic (virtual microphone)")).tag("")
                    ForEach(Devices.outputs(), id: \.uid) { Text($0.name).tag($0.name) }
                }
                Toggle(L("同时送出我的原声（播报译文时自动压低）", "Also send my own voice (ducked while the translation plays)"), isOn: $s.passthrough)
                Picker(L("回声保护", "Echo guard"), selection: $s.echoGuard) {
                    Text(L("自动（外放时开，戴耳机时关）", "Automatic (on with speakers, off with headphones)")).tag("auto")
                    Text(L("一直开", "Always on")).tag("on")
                    Text(L("一直关", "Always off")).tag("off")
                }
            }
            Section(L("译文语音", "Translation voice")) {
                Picker(L("语音", "Voice"), selection: $s.voiceName) {
                    Text(L("自动（最自然的\(Lang.of(s.remoteLang).plain)语音）", "Automatic (the most natural \(Lang.of(s.remoteLang).plain) voice)")).tag("")
                    ForEach(s.voices, id: \.identifier) { v in Text("\(v.name)（\(v.language)）").tag(v.name) }
                }
                HStack {
                    Text(L("语速", "Rate"))
                    Slider(value: $s.rate, in: 0.7...1.3, step: 0.05)
                    Text(String(format: "%.2f×", s.rate)).monospacedDigit().frame(width: 50)
                    Button(L("试听", "Preview")) { s.preview() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var subtitles: some View {
        Form {
            HStack {
                Text(L("字号", "Text size"))
                Slider(value: $overlay.fontSize, in: 13...40, step: 1)
                Text("\(Int(overlay.fontSize))").monospacedDigit().frame(width: 30)
            }
            HStack {
                Text(L("背景不透明度", "Background opacity"))
                Slider(value: $overlay.opacity, in: 0.5...1.0)
                Text("\(Int(overlay.opacity * 100))%").monospacedDigit().frame(width: 40)
            }
            Toggle(L("紧凑模式（只显示一行字幕）", "Compact mode (one line of subtitles)"), isOn: $overlay.compact)
            Toggle(L("翻译我的话", "Translate me"), isOn: $overlay.translateMe)
            Button(L("显示字幕窗", "Show Subtitles")) { AppController.shared?.showPanel() }
        }
        .formStyle(.grouped)
    }

    private var records: some View {
        let list = SessionLog.list().reversed().filter { !SessionLog.read($0).isEmpty }.prefix(30)
        return VStack(alignment: .leading, spacing: 10) {
            Text(L("每次同传自动保存双语对照文字记录，不保存录音。", "Every session is saved as a bilingual text transcript. No audio is recorded.")).font(.system(size: 12)).foregroundStyle(.secondary)
            List(Array(list), id: \.self) { url in
                HStack {
                    Text(prettyDate(url)).monospacedDigit()
                    Text(L("\(SessionLog.read(url).count) 句", "\(SessionLog.read(url).count) lines")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("打开", "Open")) { open(url) }
                }
            }
            HStack {
                Text(Paths.sessions.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("打开记录文件夹", "Open Folder")) { NSWorkspace.shared.open(Paths.sessions) }
            }
        }
    }

    private var advanced: some View {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        let link = "ln -sf \"\(exe)\" \"$(brew --prefix 2>/dev/null || echo /usr/local)/bin/hushpiece\""
        let mcp = """
        {
          "mcpServers": {
            "hushpiece": { "command": "\(exe)", "args": ["mcp"] }
          }
        }
        """
        return Form {
            Section(L("命令行 hushpiece", "Command line: hushpiece")) {
                Text(L("在终端运行下面这行，就能使用 hushpiece start / stop / status / say / transcript 等命令。", "Run this line in Terminal to get hushpiece start / stop / status / say / transcript and friends.")).font(.caption).foregroundStyle(.secondary)
                copyRow(link)
            }
            Section(L("MCP（让 AI 助手读取会议记录、控制同传）", "MCP (let AI assistants read transcripts and control interpreting)")) {
                Text(L("默认只读；要让 AI 启停同传或替你发言，在 args 里加 \"--allow-write\"。", "Read-only by default; add \"--allow-write\" to args to let the AI start/stop interpreting or speak for you.")).font(.caption).foregroundStyle(.secondary)
                copyRow(mcp)
            }
        }
        .formStyle(.grouped)
    }

    private func copyRow(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button(L("复制", "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func open(_ url: URL) {
        let md = url.deletingPathExtension().appendingPathExtension("md")
        try? SessionLog.markdown(url).write(to: md, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(md)
    }

    private func prettyDate(_ url: URL) -> String {
        let id = url.deletingPathExtension().lastPathComponent
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
        let out = DateFormatter(); out.dateFormat = L("yyyy年M月d日 HH:mm", "MMM d, yyyy HH:mm")
        return f.date(from: id).map(out.string(from:)) ?? id
    }

    private func runningApps() -> [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName)
        var all = Set(names)
        if !s.remoteApp.isEmpty { all.insert(s.remoteApp) }
        return all.sorted()
    }
}
