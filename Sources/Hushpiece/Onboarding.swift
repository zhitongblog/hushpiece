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
    @Published var meetingApp = "企业微信"

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
        downloadNote = "正在下载语音识别模型…"
        for l in [remoteLang, myLang] {
            do { try await StreamTranscriber.ensureAssets(Locale(identifier: l)) }
            catch { downloadNote = "\(Lang.of(l).name) 语音模型下载失败：\(error.localizedDescription)" }
        }
        downloadNote = "正在准备翻译模型（如果弹出下载确认，请点“下载”）…"
        c1 = .init(source: Locale.Language(identifier: translationLang(remoteLang)), target: Locale.Language(identifier: translationLang(myLang)))
    }

    func translationPrepared(first: Bool, error: Error?) async {
        if let error { downloadNote = "翻译模型准备失败：\(error.localizedDescription)" }
        if first {
            c2 = .init(source: Locale.Language(identifier: translationLang(myLang)), target: Locale.Language(identifier: translationLang(remoteLang)))
        } else {
            downloading = false
            await refresh()
            downloadNote = done(.models) ? "模型都准备好了" : downloadNote
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
        guard let first = bufs.first else { testError = "没有可用的\(remote.plain)语音"; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushpiece-test-\(UUID().uuidString).caf")
        do {
            let f = try AVAudioFile(forWriting: url, settings: first.format.settings)
            for b in bufs { try f.write(from: b) }
        } catch { testError = "生成测试语音失败：\(error.localizedDescription)"; return }
        defer { try? FileManager.default.removeItem(at: url) }

        let asr = StreamTranscriber(locale: Locale(identifier: remoteLang))
        var heard: [String] = []
        let lock = NSLock()
        asr.onFinal = { t in lock.lock(); heard.append(t); lock.unlock() }
        do {
            try await asr.start()
            try FileSource.stream(url, realtime: false) { asr.feed($0) }
            await asr.finish()
        } catch { testError = "识别失败：\(error.localizedDescription)"; return }
        lock.lock(); let text = heard.joined(separator: " "); lock.unlock()
        guard !text.isEmpty else { testError = "没有识别出内容，请先完成第 2 步下载模型"; return }
        testHeard = text
        do {
            testTranslated = try await Translator(from: translationLang(remoteLang), to: translationLang(myLang)).translate(text)
        } catch { testError = "翻译失败：\(error.localizedDescription)。请先完成第 2 步下载模型" }
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
    static let meetingApps: [(String, String)] = [
        ("企业微信", "左下角 ☰ → 设置 → 音视频 → 麦克风"),
        ("飞书", "会议中点麦克风按钮旁的 ˄ → 选择麦克风"),
        ("钉钉", "会议中点麦克风按钮旁的 ˄ → 选择麦克风"),
        ("腾讯会议", "会议中点麦克风按钮旁的 ˄ → 选择麦克风"),
        ("微信", "通话中点麦克风按钮旁的 ˄ → 选择麦克风"),
        ("Zoom", "zoom.us → 设置 → 音频 → 麦克风"),
        ("Teams", "设置 → 设备 → 麦克风"),
        ("其他", "在会议软件的音频设置里，把麦克风选成虚拟麦克风"),
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
                    Text("耳语同传").font(.system(size: 15, weight: .semibold))
                    Text("Hushpiece").font(.system(size: 11)).foregroundStyle(.secondary)
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
                .accessibilityLabel(title(s) + (m.done(s) ? "，已完成" : ""))
            }
            Spacer()
            Text("所有识别和翻译都在这台 Mac 上完成，不联网、不上传。")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 16)
        }
        .padding(.horizontal, 14)
        .frame(width: 230)
        .background(Color.primary.opacity(0.03))
    }

    private func title(_ s: OnboardingModel.Step) -> String {
        switch s {
        case .language: return "1  选择语言"
        case .models: return "2  下载模型"
        case .mic: return "3  麦克风权限"
        case .screen: return "4  听对方的声音"
        case .virtualMic: return "5  虚拟麦克风"
        case .test: return "6  试一试"
        case .meetingApp: return "7  设置会议软件"
        }
    }

    @ViewBuilder private var content: some View {
        switch m.step {
        case .language:
            page("你和谁开会？", "选你说的语言和对方说的语言。字幕显示成你的语言；你说的话会翻成对方的语言。") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        Text("我说").foregroundStyle(.secondary)
                        Picker("", selection: $m.myLang) { ForEach(Lang.all) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 220)
                    }
                    GridRow {
                        Text("对方说").foregroundStyle(.secondary)
                        Picker("", selection: $m.remoteLang) { ForEach(Lang.all) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 220)
                    }
                }
                if m.myLang == m.remoteLang {
                    note("两边选了同一种语言", warn: true)
                }
            }
        case .models:
            page("下载\(m.remote.plain)和\(m.mine.plain)的模型", "语音识别和翻译模型由 macOS 提供，下载一次以后就能离线使用。翻译模型下载时系统会弹窗确认。") {
                status(m.asrOK, "语音识别：\(m.remote.name)、\(m.mine.name)")
                status(m.mtOK, "翻译：\(m.remote.plain) ⇄ \(m.mine.plain)")
                if !m.done(.models) {
                    Button(m.downloading ? "下载中…" : "下载") { Task { await m.download() } }
                        .disabled(m.downloading).controlSize(.large).buttonStyle(.borderedProminent)
                }
                if !m.downloadNote.isEmpty { note(m.downloadNote) }
            }
        case .mic:
            page("允许使用麦克风", "用来识别你说的话。声音只在这台 Mac 上处理，不会保存录音。") {
                status(m.micOK, m.micOK ? "已允许" : "还没有允许")
                if !m.micOK { Button("允许使用麦克风") { Task { await m.requestMic() } }.controlSize(.large).buttonStyle(.borderedProminent) }
            }
        case .screen:
            page("允许听到对方的声音", "macOS 把“听系统声音”归在“屏幕与系统录音”权限里。耳语同传只取声音、不看画面，也不保存音频。") {
                status(m.screenOK, m.screenOK ? "已允许" : "还没有允许")
                if !m.screenOK {
                    Button("打开授权") { m.requestScreen() }.controlSize(.large).buttonStyle(.borderedProminent)
                    if m.screenAsked { note("在系统设置里打开“耳语同传”的开关后，需要退出并重新打开耳语同传才生效。") }
                }
                note("同传时菜单栏会出现紫色的录制图标，这是正常的。不要点它的“停止”；万一点了，耳语同传会在 1 秒内自动重新连上。")
            }
        case .virtualMic:
            page("让对方听到你的译文", "把你说的\(m.mine.plain)翻成\(m.remote.plain)后念出来，需要一个“虚拟麦克风”，会议软件从这里收你的声音。") {
                if let vm = m.virtualMic {
                    status(true, "已找到虚拟麦克风：\(vm)")
                } else {
                    status(false, "还没有虚拟麦克风")
                    note("在终端运行下面的命令安装免费的 BlackHole（需要输入开机密码）。如果装完仍没显示，重启一次电脑即可。")
                    copyBox("brew install --cask blackhole-2ch")
                    note("也可以先跳过：没有虚拟麦克风时只显示字幕，你的译文显示在屏幕上，自己念给对方听。")
                }
            }
        case .test:
            page("试一试", "用\(m.remote.plain)语音念一句话，看能不能识别并翻成\(m.mine.plain)。全程在本机完成。") {
                Button(m.testRunning ? "测试中…" : "开始测试") { Task { await m.runTest() } }
                    .disabled(m.testRunning).controlSize(.large).buttonStyle(.borderedProminent)
                if !m.testHeard.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("听到：\(m.testHeard)").font(.system(size: 13)).foregroundStyle(.secondary)
                        if !m.testTranslated.isEmpty { Text(m.testTranslated).font(.system(size: 18, weight: .semibold)) }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                if !m.testError.isEmpty { note(m.testError, warn: true) }
            }
        case .meetingApp:
            page("在会议软件里选择麦克风", "把会议软件的麦克风设成虚拟麦克风，扬声器保持耳机或电脑扬声器。") {
                Picker("会议软件", selection: $m.meetingApp) {
                    ForEach(OnboardingModel.meetingApps, id: \.0) { Text($0.0).tag($0.0) }
                }.frame(width: 260)
                let how = OnboardingModel.meetingApps.first { $0.0 == m.meetingApp }?.1 ?? ""
                note("\(how)，选 \(m.virtualMic ?? "虚拟麦克风")。")
                if m.listeners.isEmpty {
                    status(false, "还没有检测到会议软件在使用 \(m.virtualMic ?? "虚拟麦克风")（进入会议或打开音频设置后会自动检测）")
                } else {
                    status(true, "\(m.listeners.joined(separator: "、")) 正在使用 \(m.virtualMic ?? "")")
                }
                note("会后不用改回来：下次开会直接开始同传即可。不开同传时对方听不到你，记得开会前先点“开始同传”。")
            }
        }
    }

    private var footer: some View {
        HStack {
            if m.step != .language {
                Button("上一步") { m.step = OnboardingModel.Step(rawValue: m.step.rawValue - 1)! }
            }
            Spacer()
            if m.step == .meetingApp {
                Button("稍后再说") { done(false) }
                Button("开始同传") { done(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("下一步") { m.step = OnboardingModel.Step(rawValue: m.step.rawValue + 1)! }
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
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
