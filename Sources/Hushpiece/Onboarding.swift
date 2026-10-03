import AppKit
import AVFoundation
import CoreGraphics
import Speech
import SwiftUI
import Translation

/// The app icon drawn in SwiftUI (so it shows the same mark when run outside the bundle).
struct BrandMark: View {
    var size: CGFloat = 64
    var body: some View {
        let hs: [CGFloat] = [80, 160, 250, 360, 300, 190, 110, 110, 190, 300, 360, 250, 160, 80]
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.204, green: 0.212, blue: 0.31), Color(red: 0.043, green: 0.047, blue: 0.078)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: size * 0.0155) {
                ForEach(Array(hs.enumerated()), id: \.offset) { i, h in
                    Capsule().fill(i < 7 ? Color.white : Palette.amber)
                        .frame(width: size * 0.029, height: size * h / 824)
                        .padding(.leading, i == 7 ? size * 0.0155 : 0)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Model

@MainActor final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case language, models, mic, screen, virtualMic, test, meetingApp }

    @Published var step: Step = .language
    @Published var myLang = Prefs.shared.myLang { didSet { Prefs.shared.myLang = myLang; Task { await refresh() } } }
    @Published var remoteLang = Prefs.shared.remoteLang { didSet { Prefs.shared.remoteLang = remoteLang; Task { await refresh() } } }

    @Published var asrOK = false
    @Published var mtOK = false
    @Published var downloading = false
    @Published var downloadNote = ""
    @Published var c1: TranslationSession.Configuration?
    @Published var c2: TranslationSession.Configuration?

    @Published var micOK = false
    @Published var screenOK = false
    @Published var screenAsked = false
    @Published var virtualMic: String?
    @Published var listeners: [String] = []
    @Published var meetingApp = UILang.isZh ? "wecom" : "zoom"

    @Published var testRunning = false
    @Published var testHeard = ""
    @Published var testTranslated = ""
    @Published var testError = ""

    private var timer: Timer?

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshLive() }
        }
    }

    var remote: Lang { Lang.of(remoteLang) }
    var mine: Lang { Lang.of(myLang) }

    func done(_ s: Step) -> Bool {
        switch s {
        case .language: return myLang != remoteLang
        case .models: return asrOK && mtOK
        case .mic: return micOK
        case .screen: return screenOK
        case .virtualMic: return virtualMic != nil
        case .test: return !testTranslated.isEmpty
        case .meetingApp: return !listeners.isEmpty
        }
    }

    func refresh() async {
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        asrOK = installed.contains(remoteLang) && installed.contains(myLang)
        let a = translationLang(remoteLang), b = translationLang(myLang)
        let fwd = await Translator.isInstalled(from: a, to: b)
        let back = await Translator.isInstalled(from: b, to: a)
        mtOK = fwd && back
        await refreshLive()
    }

    func refreshLive() async {
        micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenOK = CGPreflightScreenCaptureAccess()
        let vm = Devices.blackHole()
        virtualMic = vm?.name
        listeners = vm.map(Devices.listeners(of:)) ?? []
    }

    /// Speech models download silently; translation models need the system's confirmation
    /// sheet, which `.translationTask` in the view presents when c1 / c2 are set.
    func download() async {
        downloading = true
        downloadNote = L("正在下载语音识别模型…", "Downloading speech recognition models…")
        for l in [remoteLang, myLang] {
            do { try await StreamTranscriber.ensureAssets(Locale(identifier: l)) }
            catch { downloadNote = L("\(Lang.of(l).name) 语音模型下载失败：", "Couldn't download the \(Lang.of(l).name) speech model: ") + error.localizedDescription }
        }
        downloadNote = L("正在准备翻译模型（如果弹出下载确认，请点“下载”）…", "Preparing translation models (if macOS asks to download, click Download)…")
        c1 = .init(source: Locale.Language(identifier: translationLang(remoteLang)), target: Locale.Language(identifier: translationLang(myLang)))
    }

    func translationPrepared(first: Bool, error: Error?) async {
        if let error { downloadNote = L("翻译模型准备失败：", "Couldn't prepare the translation models: ") + error.localizedDescription }
        if first {
            c2 = .init(source: Locale.Language(identifier: translationLang(myLang)), target: Locale.Language(identifier: translationLang(remoteLang)))
        } else {
            downloading = false
            await refresh()
            downloadNote = done(.models) ? L("模型都准备好了", "All models are ready") : downloadNote
        }
    }

    /// From the menu: get speech models for a newly picked language in the background.
    static func ensureModelsQuietly() async {
        for l in [Prefs.shared.remoteLang, Prefs.shared.myLang] {
            try? await StreamTranscriber.ensureAssets(Locale(identifier: l))
        }
    }

    func requestMic() async {
        micOK = await AVCaptureDevice.requestAccess(for: .audio)
        if !micOK { openPrivacy("Privacy_Microphone") }
    }

    func requestScreen() {
        screenAsked = true
        if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
    }

    func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Speaks a sample sentence in the other side's language into a file, recognizes it and
    /// translates it — the same models the live session uses, without needing a call.
    func runTest() async {
        testRunning = true; testHeard = ""; testTranslated = ""; testError = ""
        defer { testRunning = false }
        let sample = Self.samples[translationLang(remoteLang)] ?? Self.samples["en"]!
        let voice = Voice(language: remoteLang, name: nil, rate: 1.0)
        let bufs = await voice.render(sample)
        guard let first = bufs.first else { testError = L("没有可用的\(remote.plain)语音", "No \(remote.plain) voice is available"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushpiece-test-\(UUID().uuidString).caf")
        do {
            let f = try AVAudioFile(forWriting: url, settings: first.format.settings)
            for b in bufs { try f.write(from: b) }
        } catch { testError = L("生成测试语音失败：", "Couldn't create the test audio: ") + error.localizedDescription; return }
        defer { try? FileManager.default.removeItem(at: url) }

        let asr = StreamTranscriber(locale: Locale(identifier: remoteLang))
        var heard: [String] = []
        let lock = NSLock()
        asr.onFinal = { t in lock.lock(); heard.append(t); lock.unlock() }
        do {
            try await asr.start()
            try FileSource.stream(url, realtime: false) { asr.feed($0) }
            await asr.finish()
        } catch { testError = L("识别失败：", "Recognition failed: ") + error.localizedDescription; return }
        lock.lock(); let text = heard.joined(separator: " "); lock.unlock()
        guard !text.isEmpty else { testError = L("没有识别出内容，请先完成第 2 步下载模型", "Nothing was recognised. Finish step 2 (download models) first"); return }
        testHeard = text
        do {
            testTranslated = try await Translator(from: translationLang(remoteLang), to: translationLang(myLang)).translate(text)
        } catch { testError = L("翻译失败：", "Translation failed: ") + error.localizedDescription + L("。请先完成第 2 步下载模型", ". Finish step 2 (download models) first") }
    }

    static let samples: [String: String] = [
        "en": "Could you send me the report by Friday?",
        "ja": "金曜日までに報告書を送っていただけますか？",
        "ko": "금요일까지 보고서를 보내 주실 수 있나요?",
        "fr": "Pouvez-vous m'envoyer le rapport avant vendredi ?",
        "de": "Können Sie mir den Bericht bis Freitag schicken?",
        "es": "¿Puede enviarme el informe antes del viernes?",
        "it": "Può inviarmi il rapporto entro venerdì?",
        "pt": "Você pode me enviar o relatório até sexta-feira?",
        "zh-Hans": "你能在周五之前把报告发给我吗？",
        "zh-TW": "你能在週五之前把報告發給我嗎？",
    ]

    /// Where each meeting app keeps its microphone setting. The in-call ˄ menu next to the mic
    /// button works in all of them.
    struct MeetingApp: Hashable { let id: String; let name: String; let how: String }
    static let meetingApps: [MeetingApp] = [
        MeetingApp(id: "zoom", name: "Zoom", how: L("zoom.us → 设置 → 音频 → 麦克风", "zoom.us → Settings → Audio → Microphone")),
        MeetingApp(id: "teams", name: "Teams", how: L("设置 → 设备 → 麦克风", "Settings → Devices → Microphone")),
        MeetingApp(id: "meet", name: "Google Meet", how: L("会议中点 ⋮ → 设置 → 音频 → 麦克风", "In a call: ⋮ → Settings → Audio → Microphone")),
        MeetingApp(id: "wecom", name: L("企业微信", "WeCom"), how: L("左下角 ☰ → 设置 → 音视频 → 麦克风", "☰ (bottom left) → Settings → Audio & Video → Microphone")),
        MeetingApp(id: "feishu", name: L("飞书", "Feishu / Lark"), how: L("会议中点麦克风按钮旁的 ˄ → 选择麦克风", "In a meeting: ˄ next to the microphone button → choose the microphone")),
        MeetingApp(id: "dingtalk", name: L("钉钉", "DingTalk"), how: L("会议中点麦克风按钮旁的 ˄ → 选择麦克风", "In a meeting: ˄ next to the microphone button → choose the microphone")),
        MeetingApp(id: "tencent", name: L("腾讯会议", "Tencent Meeting / VooV"), how: L("会议中点麦克风按钮旁的 ˄ → 选择麦克风", "In a meeting: ˄ next to the microphone button → choose the microphone")),
        MeetingApp(id: "wechat", name: L("微信", "WeChat"), how: L("通话中点麦克风按钮旁的 ˄ → 选择麦克风", "In a call: ˄ next to the microphone button → choose the microphone")),
        MeetingApp(id: "other", name: L("其他", "Other"), how: L("在会议软件的音频设置里，把麦克风选成虚拟麦克风", "In the meeting app's audio settings, choose the virtual microphone")),
    ]
}

// MARK: - View

struct OnboardingView: View {
    @StateObject var m: OnboardingModel
    var done: (Bool) -> Void

    init(m: OnboardingModel, done: @escaping (Bool) -> Void) {
        _m = StateObject(wrappedValue: m)
        self.done = done
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView { content.padding(28).frame(maxWidth: .infinity, alignment: .leading) }
                Divider()
                footer.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .frame(width: 760, height: 520)
        .translationTask(m.c1) { session in
            var err: Error?
            do { try await session.prepareTranslation() } catch { err = error }
            await m.translationPrepared(first: true, error: err)
        }
        .translationTask(m.c2) { session in
            var err: Error?
            do { try await session.prepareTranslation() } catch { err = error }
            await m.translationPrepared(first: false, error: err)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                BrandMark(size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("耳语同传", "Hushpiece")).font(.system(size: 15, weight: .semibold))
                    Text(L("Hushpiece", "耳语同传")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 18).padding(.top, 30)
            ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                Button { m.step = s } label: {
                    HStack(spacing: 8) {
                        Image(systemName: m.done(s) ? "checkmark.circle.fill" : (m.step == s ? "circle.inset.filled" : "circle"))
                            .foregroundStyle(m.done(s) ? Color.green : (m.step == s ? Color.accentColor : Color.secondary))
                        Text(title(s)).font(.system(size: 13, weight: m.step == s ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(m.step == s ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(s) + (m.done(s) ? L("，已完成", ", done") : ""))
            }
            Spacer()
            Text(L("所有识别和翻译都在这台 Mac 上完成，不联网、不上传。", "Everything is recognised and translated on this Mac. Nothing goes online."))
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 16)
        }
        .padding(.horizontal, 14)
        .frame(width: 230)
        .background(Color.primary.opacity(0.03))
    }

    private func title(_ s: OnboardingModel.Step) -> String {
        switch s {
        case .language: return L("1  选择语言", "1  Languages")
        case .models: return L("2  下载模型", "2  Download models")
        case .mic: return L("3  麦克风权限", "3  Microphone")
        case .screen: return L("4  听对方的声音", "4  Hear the other side")
        case .virtualMic: return L("5  虚拟麦克风", "5  Virtual microphone")
        case .test: return L("6  试一试", "6  Try it")
        case .meetingApp: return L("7  设置会议软件", "7  Meeting app")
        }
    }

    @ViewBuilder private var content: some View {
        switch m.step {
        case .language:
            page(L("你和谁开会？", "Who are you meeting?"), L("选你说的语言和对方说的语言。字幕显示成你的语言；你说的话会翻成对方的语言。", "Pick the language you speak and the language they speak. Subtitles appear in yours; what you say is translated into theirs.")) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        Text(L("我说", "I speak")).foregroundStyle(.secondary)
                        Picker("", selection: $m.myLang) { ForEach(Lang.all) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 220)
                    }
                    GridRow {
                        Text(L("对方说", "They speak")).foregroundStyle(.secondary)
                        Picker("", selection: $m.remoteLang) { ForEach(Lang.all) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 220)
                    }
                }
                if m.myLang == m.remoteLang {
                    note(L("两边选了同一种语言", "Both sides are set to the same language"), warn: true)
                }
            }
        case .models:
            page(L("下载\(m.remote.plain)和\(m.mine.plain)的模型", "Download \(m.remote.plain) and \(m.mine.plain) models"), L("语音识别和翻译模型由 macOS 提供，下载一次以后就能离线使用。翻译模型下载时系统会弹窗确认。", "Speech recognition and translation models come with macOS; download them once and they work offline. macOS asks you to confirm the translation download.")) {
                status(m.asrOK, L("语音识别：", "Speech recognition: ") + "\(m.remote.name), \(m.mine.name)")
                status(m.mtOK, L("翻译：", "Translation: ") + "\(m.remote.plain) ⇄ \(m.mine.plain)")
                if !m.done(.models) {
                    Button(m.downloading ? L("下载中…", "Downloading…") : L("下载", "Download")) { Task { await m.download() } }
                        .disabled(m.downloading).controlSize(.large).buttonStyle(.borderedProminent)
                }
                if !m.downloadNote.isEmpty { note(m.downloadNote) }
            }
        case .mic:
            page(L("允许使用麦克风", "Allow the microphone"), L("用来识别你说的话。声音只在这台 Mac 上处理，不会保存录音。", "Used to recognise what you say. Audio is processed on this Mac and never recorded.")) {
                status(m.micOK, m.micOK ? L("已允许", "Allowed") : L("还没有允许", "Not allowed yet"))
                if !m.micOK { Button(L("允许使用麦克风", "Allow Microphone")) { Task { await m.requestMic() } }.controlSize(.large).buttonStyle(.borderedProminent) }
            }
        case .screen:
            page(L("允许听到对方的声音", "Let it hear the other side"), L("macOS 把“听系统声音”归在“屏幕与系统录音”权限里。耳语同传只取声音、不看画面，也不保存音频。", "macOS files \"hearing system audio\" under Screen & System Audio Recording. Hushpiece uses the audio only: it never looks at the screen and never saves audio.")) {
                status(m.screenOK, m.screenOK ? L("已允许", "Allowed") : L("还没有允许", "Not allowed yet"))
                if !m.screenOK {
                    Button(L("打开授权", "Grant Access")) { m.requestScreen() }.controlSize(.large).buttonStyle(.borderedProminent)
                    if m.screenAsked { note(L("在系统设置里打开“耳语同传”的开关后，需要退出并重新打开耳语同传才生效。", "After switching Hushpiece on in System Settings, quit and reopen Hushpiece for it to take effect.")) }
                }
                note(L("同传时菜单栏会出现紫色的录制图标，这是正常的。不要点它的“停止”；万一点了，耳语同传会在 1 秒内自动重新连上。", "While interpreting, a purple recording icon shows in the menu bar; that's normal. Don't click its Stop. If you do, Hushpiece reconnects within a second."))
            }
        case .virtualMic:
            page(L("让对方听到你的译文", "Let them hear your translation"), L("把你说的\(m.mine.plain)翻成\(m.remote.plain)后念出来，需要一个“虚拟麦克风”，会议软件从这里收你的声音。", "To speak your \(m.mine.plain) to them in \(m.remote.plain), Hushpiece needs a \"virtual microphone\" for the meeting app to listen to.")) {
                if let vm = m.virtualMic {
                    status(true, L("已找到虚拟麦克风：", "Virtual microphone found: ") + vm)
                } else {
#if APPSTORE
                    // App Store build: no third-party driver recommendations (guideline 2.4.5).
                    status(false, L("没有找到虚拟音频设备", "No virtual audio device found"))
                    note(L("如果你的 Mac 上已经有虚拟音频设备，耳语同传会自动使用它。没有也没关系：字幕照常显示，你的\(m.remote.plain)译文显示在字幕窗右侧，可以自己念，或复制到会议的聊天框。", "If your Mac already has a virtual audio device, Hushpiece uses it automatically. Without one, subtitles still work and your \(m.remote.plain) translation appears on the right of the panel to read out or paste into the chat."))
#else
                    status(false, L("还没有虚拟麦克风", "No virtual microphone yet"))
                    note(L("在终端运行下面的命令安装免费的 BlackHole（需要输入开机密码）。如果装完仍没显示，重启一次电脑即可。", "Run this in Terminal to install the free BlackHole (asks for your login password). If it still doesn't show up afterwards, restart the Mac once."))
                    copyBox("brew install --cask blackhole-2ch")
                    note(L("也可以先跳过：没有虚拟麦克风时只显示字幕，你的译文显示在屏幕上，自己念给对方听。", "Or skip this for now: without a virtual microphone you get subtitles, and your translation is shown on screen for you to read out."))
#endif
                }
            }
        case .test:
            page(L("试一试", "Try it"), L("用\(m.remote.plain)语音念一句话，看能不能识别并翻成\(m.mine.plain)。全程在本机完成。", "Speak a sentence in \(m.remote.plain) and check it is recognised and translated into \(m.mine.plain), all on this Mac.")) {
                Button(m.testRunning ? L("测试中…", "Testing…") : L("开始测试", "Run Test")) { Task { await m.runTest() } }
                    .disabled(m.testRunning).controlSize(.large).buttonStyle(.borderedProminent)
                if !m.testHeard.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("听到：", "Heard: ") + m.testHeard).font(.system(size: 13)).foregroundStyle(.secondary)
                        if !m.testTranslated.isEmpty { Text(m.testTranslated).font(.system(size: 18, weight: .semibold)) }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                if !m.testError.isEmpty { note(m.testError, warn: true) }
            }
        case .meetingApp:
            page(L("在会议软件里选择麦克风", "Choose the microphone in your meeting app"), L("把会议软件的麦克风设成虚拟麦克风，扬声器保持耳机或电脑扬声器。", "Set the meeting app's microphone to the virtual microphone; keep the speaker on your headphones or the Mac's speakers.")) {
                Picker(L("会议软件", "Meeting app"), selection: $m.meetingApp) {
                    ForEach(OnboardingModel.meetingApps, id: \.id) { Text($0.name).tag($0.id) }
                }.frame(width: 300)
                let how = OnboardingModel.meetingApps.first { $0.id == m.meetingApp }?.how ?? ""
                note(how + L("，选 ", ", then pick ") + (m.virtualMic ?? L("虚拟麦克风", "the virtual microphone")) + L("。", "."))
                if m.listeners.isEmpty {
                    status(false, L("还没有检测到会议软件在使用 \(m.virtualMic ?? "虚拟麦克风")（进入会议或打开音频设置后会自动检测）", "No meeting app is using \(m.virtualMic ?? "the virtual microphone") yet (detected automatically once you join a meeting or open its audio settings)"))
                } else {
                    status(true, L("\(m.listeners.joined(separator: "、")) 正在使用 \(m.virtualMic ?? "")", "\(m.listeners.joined(separator: ", ")) is using \(m.virtualMic ?? "")"))
                }
                note(L("会后不用改回来：下次开会直接开始同传即可。不开同传时对方听不到你，记得开会前先点“开始同传”。", "No need to switch back afterwards: just start interpreting at your next meeting. While Hushpiece isn't interpreting, they can't hear you, so start it before the meeting."))
            }
        }
    }

    private var footer: some View {
        HStack {
            if m.step != .language {
                Button(L("上一步", "Back")) { m.step = OnboardingModel.Step(rawValue: m.step.rawValue - 1)! }
            }
            Spacer()
            if m.step == .meetingApp {
                Button(L("稍后再说", "Later")) { done(false) }
                Button(L("开始同传", "Start Interpreting")) { done(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button(L("下一步", "Next")) { m.step = OnboardingModel.Step(rawValue: m.step.rawValue + 1)! }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: building blocks

    private func page<C: View>(_ title: String, _ text: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            body()
        }
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(text).font(.system(size: 13))
        }
    }

    private func note(_ text: String, warn: Bool = false) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(warn ? Color.orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copyBox(_ cmd: String) -> some View {
        HStack {
            Text(cmd).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button(L("复制", "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
