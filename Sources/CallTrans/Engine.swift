import AppKit
import AVFoundation
import Foundation

struct RunConfig {
    var remoteLocale = "en-GB"
    var myLocale = "zh-CN"
    var remoteApp: String?           // only capture this app's audio (e.g. "WeChat")
    var micName: String?
    var outputName: String?          // virtual mic device; default: first BlackHole
    var voiceName: String?
    var rate = 1.0
    var passthrough = true           // also send my original voice to the call
    var gate = true                  // ignore my mic while the other side is talking (echo guard)
    var overlay = true
    var translateMe = true
    var fontSize = 20.0
    var remoteFile: String?          // test: feed this file as "their" audio instead of system audio
    var micFile: String?             // test: feed this file as "my" audio instead of the microphone
    var micFileDelay = 2.0

    init(_ a: Args) {
        remoteLocale = a.string("remote-lang") ?? remoteLocale
        myLocale = a.string("my-lang") ?? myLocale
        remoteApp = a.string("app")
        micName = a.string("mic")
        outputName = a.string("output")
        voiceName = a.string("voice")
        rate = a.double("rate", rate)
        passthrough = !a.bool("no-passthrough")
        gate = !a.bool("no-gate")
        overlay = !a.bool("no-overlay")
        translateMe = !a.bool("subtitles-only")
        fontSize = a.double("font-size", fontSize)
        remoteFile = a.string("remote-file")
        micFile = a.string("mic-file")
        micFileDelay = a.double("mic-file-delay", micFileDelay)
    }
}

/// Wires: system audio → en ASR → en→zh → overlay;  mic → zh ASR → zh→en → TTS → virtual mic.
final class Engine {
    let cfg: RunConfig
    let model = OverlayModel()
    let log = SessionLog()

    private let remoteASR: StreamTranscriber
    private let myASR: StreamTranscriber
    private let toMine: Translator      // remote language → my language
    private let toMineFast: Translator  // for live previews of unfinished sentences
    private let toRemote: Translator    // my language → remote language
    private let voice: Voice
    private let sys = SystemAudioCapture()
    private let mic = MicCapture()
    private var output: CallOutput?
    private var speakQueue: AsyncStream<String>.Continuation?

    private let gateLock = NSLock()
    private var lastRemoteLoud = Date.distantPast
    private var lastMicLoud = Date.distantPast
    private var remotePending = false   // volatile text not yet finalized
    private var mePending = false
    private let pauseToCommit = 0.9     // seconds of silence that end a sentence
    private let pauseAfterStop = 0.4    // …or this much if the recognizer already put a full stop
    private var remoteLiveText = ""
    private var meLiveText = ""

    private func shouldCommit(_ pending: Bool, _ text: String, _ silence: TimeInterval) -> Bool {
        guard pending else { return false }
        if silence > pauseToCommit { return true }
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return silence > pauseAfterStop && "。？！.?!".contains(last)
    }
    private var previewBusy = false
    private var lastPreview = Date.distantPast
    private var status: Status
    private let statusLock = NSLock()
    private func update(_ f: (inout Status) -> Void) { statusLock.lock(); f(&status); statusLock.unlock() }
    private var timers: [Timer] = []

    init(_ cfg: RunConfig) {
        self.cfg = cfg
        let remoteLang = translationLang(cfg.remoteLocale)
        let myLang = translationLang(cfg.myLocale)
        remoteASR = StreamTranscriber(locale: Locale(identifier: cfg.remoteLocale))
        myASR = StreamTranscriber(locale: Locale(identifier: cfg.myLocale))
        toMine = Translator(from: remoteLang, to: myLang)
        toMineFast = Translator(from: remoteLang, to: myLang, highFidelity: false)
        toRemote = Translator(from: myLang, to: remoteLang)
        voice = Voice(language: cfg.remoteLocale, name: cfg.voiceName, rate: cfg.rate)
        status = Status(pid: getpid(), session: log.id, started: Date(), updated: Date(),
                        remoteSource: "-", micDevice: "-", outputDevice: nil, translateMe: cfg.translateMe,
                        remoteLines: 0, meLines: 0, lastRemote: nil, lastMe: nil, errors: [])
        model.translateMe = cfg.translateMe
        model.fontSize = cfg.fontSize
    }

    func start() async {
        model.onType = { [weak self] t in self?.typed(t) }
        update { $0.write() }

        // Translation models must be installed (`calltrans setup`).
        let myLang = translationLang(cfg.myLocale)
        let remoteLang = translationLang(cfg.remoteLocale)
        let fwd = await Translator.isInstalled(from: remoteLang, to: myLang)
        let back = await Translator.isInstalled(from: myLang, to: remoteLang)
        if !fwd || !back {
            fail("翻译模型未安装：请先运行 calltrans setup")
        }

        // Output (virtual mic). Without it we run subtitles-only and show the English for me to read aloud.
        let outDev = cfg.outputName.flatMap { Devices.find($0, output: true) } ?? Devices.blackHole()
        if let outDev {
            do {
                output = try CallOutput(device: outDev)
                update { $0.outputDevice = outDev.name }
                await MainActor.run { model.outputLabel = "我的英语 → \(outDev.name)" }
            } catch { fail("无法打开输出设备 \(outDev.name): \(error.localizedDescription)") }
        } else {
            fail("未找到虚拟麦克风 BlackHole：只显示字幕，我的英语译文请自己念")
        }

        // Speech queue: one utterance at a time.
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        speakQueue = cont
        Task.detached { [weak self] in
            for await text in stream {
                guard let self, let out = self.output else { continue }
                let bufs = await self.voice.render(text)
                await MainActor.run { self.model.speaking = true }
                await out.play(bufs)
                await MainActor.run { self.model.speaking = false }
            }
        }

        // Recognizers.
        remoteASR.onVolatile = { [weak self] t in self?.remoteVolatile(t) }
        remoteASR.onFinal = { [weak self] t in self?.remoteFinal(t) }
        myASR.onVolatile = { [weak self] t in
            self?.gateLock.lock(); self?.mePending = !t.isEmpty; self?.meLiveText = t; self?.gateLock.unlock()
            Task { @MainActor in self?.model.meLive = t }
        }
        myASR.onFinal = { [weak self] t in self?.myFinal(t) }
        do { try await remoteASR.start() } catch { fail("英文识别启动失败: \(error.localizedDescription)") }
        do { try await myASR.start() } catch { fail("中文识别启动失败: \(error.localizedDescription)") }

        // Their audio.
        sys.onBuffer = { [weak self] b in
            guard let self else { return }
            if rms(b) > 0.008 { self.gateLock.lock(); self.lastRemoteLoud = Date(); self.gateLock.unlock() }
            self.remoteASR.feed(b)
        }
        if let f = cfg.remoteFile {
            update { $0.remoteSource = "file " + (f as NSString).lastPathComponent }
            playFile(f, after: 2) { [weak self] b in self?.sys.onBuffer?(b) }
        } else { do {
            try await sys.start(appName: cfg.remoteApp)
            let d = sys.description_; update { $0.remoteSource = d }
        } catch {
            fail("无法采集系统声音（需要“屏幕与系统录音”权限）: \(error.localizedDescription)")
        } }

        // My audio.
        let micDev = Devices.microphone(named: cfg.micName)
        mic.onBuffer = { [weak self] b in
            guard let self else { return }
            if self.cfg.passthrough { self.output?.passMic(b) }
            if rms(b) > 0.01 { self.gateLock.lock(); self.lastMicLoud = Date(); self.gateLock.unlock() }
            self.gateLock.lock(); let remoteTalking = Date().timeIntervalSince(self.lastRemoteLoud) < 0.5; self.gateLock.unlock()
            if (self.cfg.gate && remoteTalking) || !self.model.translateMe || (self.output?.speaking ?? false) {
                if let s = FileSource.silence(like: b) { self.myASR.feed(s) }
            } else {
                self.myASR.feed(b)
            }
        }
        if let f = cfg.micFile {
            update { $0.micDevice = "file " + (f as NSString).lastPathComponent }
            playFile(f, after: cfg.micFileDelay) { [weak self] b in self?.mic.onBuffer?(b) }
        } else { do {
            try mic.start(device: micDev)
            let n = micDev?.name ?? "default"; update { $0.micDevice = n }
        } catch {
            fail("无法打开麦克风（需要麦克风权限）: \(error.localizedDescription)")
        } }

        await MainActor.run {
            model.sourceLabel = "对方 ← \(status.remoteSource)  ·  我 ← \(status.micDevice)"
            let t1 = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
            let t2 = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.writeStatus() }
            timers = [t1, t2]
        }
        Log.info("running: remote=\(status.remoteSource) mic=\(status.micDevice) out=\(status.outputDevice ?? "none") session=\(log.id)")
    }

    /// Every step is time-boxed: a system framework that never returns must not keep a
    /// meeting tool alive (and the transcript unsaved) after the user hits stop.
    func shutdown() async {
        timers.forEach { $0.invalidate() }
        let sys = self.sys, mic = self.mic, remoteASR = self.remoteASR, myASR = self.myASR
        await step("system audio", 2) { await sys.stop() }
        mic.stop()
        await step("remote ASR", 2) { await remoteASR.finish() }
        await step("my ASR", 2) { await myASR.finish() }
        try? await Task.sleep(for: .milliseconds(500))   // let the last translations land
        output?.stop()
        saveTranscript()
    }

    func simulateCaptureInterruption() async { await sys.simulateInterruption() }

    /// Idempotent; also called by the exit watchdog.
    func saveTranscript() {
        saveLock.lock(); defer { saveLock.unlock() }
        guard !saved else { return }
        saved = true
        let md = Paths.sessions.appendingPathComponent("\(log.id).md")
        try? SessionLog.markdown(log.url).write(to: md, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: Paths.status)
        Log.info("stopped; transcript at \(md.path)")
    }
    private let saveLock = NSLock()
    private var saved = false

    private func step(_ name: String, _ seconds: Double, _ body: @escaping @Sendable () async -> Void) async {
        let t0 = Date()
        let finished = await withTaskGroup(of: Bool.self) { g in
            g.addTask { await body(); return true }
            g.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await g.next() ?? false
            g.cancelAll()
            return first
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Log.info(finished ? "shutdown: \(name) ok (\(ms) ms)" : "shutdown: \(name) timed out after \(ms) ms, skipping")
    }

    /// Streams a file in real time, then keeps sending silence (like a quiet line) so the recognizer finalizes.
    private func playFile(_ path: String, after delay: Double, _ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: delay)
            var last: AVAudioPCMBuffer?
            do {
                try FileSource.stream(URL(fileURLWithPath: path), realtime: true) { b in sink(b); last = b }
            } catch { Log.info("file input failed: \(error)") }
            guard let l = last, let s = FileSource.silence(like: l) else { return }
            while true { sink(s); Thread.sleep(forTimeInterval: Double(s.frameLength) / s.format.sampleRate) }
        }
    }

    // MARK: events

    private func remoteVolatile(_ t: String) {
        gateLock.lock(); remotePending = !t.isEmpty; remoteLiveText = t; gateLock.unlock()
        Task { @MainActor in
            self.model.remoteLive = t
            if t.isEmpty { self.model.remoteLivePreview = "" }
        }
        guard t.count >= 12, !previewBusy, Date().timeIntervalSince(lastPreview) > 0.7 else { return }
        previewBusy = true
        lastPreview = Date()
        Task {
            let zh = try? await toMineFast.translate(t)
            await MainActor.run {
                if let zh, !self.model.remoteLive.isEmpty { self.model.remoteLivePreview = zh }
            }
            previewBusy = false
        }
    }

    private func remoteFinal(_ raw: String) {
        let en = normalizeEnglish(raw)
        Task {
            let zh = (try? await toMine.translate(en)) ?? "（翻译失败）"
            log.append(Entry(ts: Date(), dir: "remote", src: en, dst: zh))
            update { $0.remoteLines += 1; $0.lastRemote = zh }
            await MainActor.run { self.model.add(Line(mine: false, original: en, translated: zh)) }
        }
    }

    private func myFinal(_ zh: String) {
        Task { @MainActor in self.model.meLive = "" }
        guard model.translateMe, zh.count >= 2 else { return }
        Task {
            guard let en = try? await toRemote.translate(zh), !en.isEmpty else { return }
            log.append(Entry(ts: Date(), dir: "me", src: zh, dst: en))
            update { $0.meLines += 1; $0.lastMe = en }
            await MainActor.run { self.model.add(Line(mine: true, original: zh, translated: en)) }
            speakQueue?.yield(en)
        }
    }

    /// Typed in the overlay, or posted via `calltrans say` / MCP.
    func typed(_ text: String, translate: Bool = true) {
        Task {
            var translated = text
            if translate && containsCJK(text) {
                guard let t = try? await toRemote.translate(text) else { return }
                translated = t
            }
            let en = translated
            log.append(Entry(ts: Date(), dir: "typed", src: text, dst: en))
            update { $0.meLines += 1; $0.lastMe = en }
            await MainActor.run { self.model.add(Line(mine: true, original: text, translated: en)) }
            speakQueue?.yield(en)
        }
    }

    private func tick() {
        for r in Inbox.drain() { typed(r.text, translate: r.translate) }
        gateLock.lock()
        let now = Date()
        let active = now.timeIntervalSince(lastRemoteLoud) < 0.5
        let commitRemote = shouldCommit(remotePending, remoteLiveText, now.timeIntervalSince(lastRemoteLoud))
        let commitMe = shouldCommit(mePending, meLiveText, now.timeIntervalSince(lastMicLoud))
        if commitRemote { remotePending = false }
        if commitMe { mePending = false }
        gateLock.unlock()
        if commitRemote { Task { await remoteASR.forceFinalize() } }
        if commitMe { Task { await myASR.forceFinalize() } }
        if model.remoteActive != active { model.remoteActive = active }
    }

    private func writeStatus() {
        let on = model.translateMe
        update { $0.updated = Date(); $0.translateMe = on; $0.write() }
    }

    private func fail(_ msg: String) {
        Log.info("WARN: " + msg)
        update { $0.errors.append(msg) }
        Task { @MainActor in self.model.banner = self.model.banner.isEmpty ? msg : self.model.banner + "\n" + msg }
    }
}

/// Runs the engine with the overlay inside an NSApplication (blocks forever).
func runApp(_ cfg: RunConfig) -> Never {
    if let s = Status.read(), s.isAlive, s.pid != getpid() {
        print("CallTrans 已在运行 (pid \(s.pid))。先运行 calltrans stop。")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let engine = Engine(cfg)
    var panel: OverlayPanel?

    var quitting = false
    func quit() {
        guard !quitting else { return }
        quitting = true
        // Watchdog: whatever happens, save and exit within 6 s.
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            Log.info("shutdown watchdog fired")
            engine.saveTranscript()
            exit(0)
        }
        Task {
            await engine.shutdown()
            exit(0)
        }
    }
    engine.model.onQuit = quit
    if cfg.overlay {
        panel = OverlayPanel(model: engine.model)
        panel?.orderFrontRegardless()
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { quit() }
        src.resume()
        signalSources.append(src)
    }
    let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    signal(SIGUSR1, SIG_IGN)
    usr1.setEventHandler { Task { await engine.simulateCaptureInterruption() } }
    usr1.resume()
    signalSources.append(usr1)
    Task { await engine.start() }
    _ = panel
    app.run()
    exit(0)
}

private var signalSources: [DispatchSourceSignal] = []
