import AppKit
import AVFoundation
import Foundation
import NaturalLanguage

struct RunConfig {
    var remoteLocale = "en-GB"
    var myLocale = "zh-CN"
    var remoteApp: String?           // only capture this app's audio (e.g. "WeChat")
    var micName: String?
    var outputName: String?          // virtual mic device; default: our driver, else any loopback device
    var voiceName: String?
    var rate = 1.0
    var passthrough = true           // also send my original voice to the call
    var echoGuard = "auto"           // ignore my mic while the other side talks: auto (unless headphones) | on | off
    var speakOnlyWhenListened = true // don't speak into the virtual mic unless a meeting app is reading it
    var overlay = true
    var translateMe = true
    var fontSize = 20.0
    var remoteFile: String?          // test: feed this file as "their" audio instead of system audio
    var micFile: String?             // test: feed this file as "my" audio instead of the microphone
    var micFileDelay = 2.0

    /// Defaults come from the user's settings; CLI flags override them for this run.
    init(_ a: Args, settings st: Prefs = .shared) {
        remoteLocale = a.string("remote-lang") ?? st.remoteLang
        myLocale = a.string("my-lang") ?? st.myLang
        remoteApp = a.string("app") ?? st.remoteApp
        micName = a.string("mic") ?? st.micName
        outputName = a.string("output") ?? st.outputName
        voiceName = a.string("voice") ?? st.voiceName
        rate = a.double("rate", st.rate)
        passthrough = a.bool("no-passthrough") ? false : st.passthrough
        echoGuard = a.bool("no-gate") ? "off" : (a.string("echo-guard") ?? st.echoGuard)
        speakOnlyWhenListened = a.bool("always-speak") ? false : st.speakOnlyWhenListened
        overlay = !a.bool("no-overlay")
        translateMe = a.bool("subtitles-only") ? false : st.translateMe
        fontSize = a.double("font-size", st.fontSize)
        remoteFile = a.string("remote-file")
        micFile = a.string("mic-file")
        micFileDelay = a.double("mic-file-delay", micFileDelay)
    }
}

/// Wires: system audio → their-language ASR → translate → overlay;
///        mic → my-language ASR → translate → TTS → virtual mic (→ the meeting app).
final class Engine {
    let cfg: RunConfig
    let model: OverlayModel
    let log = SessionLog()
    let remoteL: Lang
    let myL: Lang

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
    private var gateOn = true               // echo guard currently active
    private var listeners: [String] = []    // apps reading the virtual mic right now
    private var ticks = 0

    init(_ cfg: RunConfig, model: OverlayModel) {
        self.cfg = cfg
        self.model = model
        remoteL = Lang.of(cfg.remoteLocale)
        myL = Lang.of(cfg.myLocale)
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
        model.resetForSession(remote: remoteL, mine: myL, translateMe: cfg.translateMe)
    }

    func start() async {
        model.onType = { [weak self] t in self?.typed(t) }
        update { $0.write() }

        // Translation models must be installed (`hushpiece setup`).
        let myLang = translationLang(cfg.myLocale)
        let remoteLang = translationLang(cfg.remoteLocale)
        let fwd = await Translator.isInstalled(from: remoteLang, to: myLang)
        let back = await Translator.isInstalled(from: myLang, to: remoteLang)
        if !fwd || !back {
            fail(L("\(remoteL.plain)⇄\(myL.plain) 翻译模型未安装：请在菜单栏 → 使用引导 里下载", "\(remoteL.plain)⇄\(myL.plain) translation models aren't installed: download them from the menu bar → Setup Guide"))
        }

        // Output (virtual mic). Without it we run subtitles-only and show the English for me to read aloud.
        let outDev = cfg.outputName.flatMap { Devices.find($0, output: true) } ?? Devices.blackHole()
        if let outDev {
            do {
                output = try CallOutput(device: outDev)
                update { $0.outputDevice = outDev.name }
                await MainActor.run { model.outputDevice = outDev.name }
            } catch { fail(L("无法打开输出设备 \(outDev.name)：", "Can't open output device \(outDev.name): ") + error.localizedDescription) }
        } else {
            fail(L("没有虚拟麦克风：只显示字幕，我的\(remoteL.plain)译文请自己念", "No virtual microphone: subtitles only; read your \(remoteL.plain) translation out yourself"))
        }

        // Speech queue: one utterance at a time.
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        speakQueue = cont
        Task.detached { [weak self] in
            for await text in stream {
                guard let self, let out = self.output else { continue }
                // Speaking into a virtual mic nobody is reading only means the meeting won't hear
                // it — and before the call starts, the room's chatter would be "spoken" for nothing.
                if self.cfg.speakOnlyWhenListened && self.currentListeners().isEmpty {
                    Log.info("not speaking (no app is using \(out.deviceName)): \(text)")
                    await MainActor.run { self.model.notHeard = true }
                    continue
                }
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
                do { try await remoteASR.start() } catch { fail(L("\(remoteL.plain)识别启动失败：", "\(remoteL.plain) recognition failed to start: ") + error.localizedDescription) }
        do { try await myASR.start() } catch { fail(L("\(myL.plain)识别启动失败：", "\(myL.plain) recognition failed to start: ") + error.localizedDescription) }

        // Their audio.
        sys.onBuffer = { [weak self] b in
            guard let self else { return }
            if rms(b) > 0.008 { self.gateLock.lock(); self.lastRemoteLoud = Date(); self.gateLock.unlock() }
            self.remoteASR.feed(b)
        }
        sys.onConnected = { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                self.model.captureConnected = ok
                // Once we hear them again, drop the "can't capture" warnings from the start.
                if ok {
                    self.model.banner = self.model.banner.split(separator: "\n")
                        .filter { !$0.contains(L("屏幕锁定", "screen is locked")) && !$0.contains(L("无法采集系统声音", "Can't capture system audio")) }
                        .joined(separator: "\n")
                    self.update { $0.errors.removeAll { $0.contains(L("屏幕锁定", "screen is locked")) || $0.contains(L("无法采集系统声音", "Can't capture system audio")) } }
                    let d = self.sys.description_; self.update { $0.remoteSource = d }
                    self.model.source = d == "all system audio" ? L("全部系统声音", "all system audio") : d.replacingOccurrences(of: "audio of ", with: "")
                }
            }
        }
        if let f = cfg.remoteFile {
            update { $0.remoteSource = "file " + (f as NSString).lastPathComponent }
            playFile(f, after: 2) { [weak self] b in self?.sys.onBuffer?(b) }
        } else { do {
            try await sys.start(appName: cfg.remoteApp)
            let d = sys.description_; update { $0.remoteSource = d }
        } catch {
            // No display = the screen is locked: ScreenCaptureKit has nothing to attach to until
            // the user unlocks. Anything else is almost always the missing permission.
            if (error as NSError).code == 2, (error as NSError).domain == "hushpiece" {
                fail(L("屏幕锁定时听不到对方的声音，解锁后自动恢复", "Can't hear the other side while the screen is locked; resumes after you unlock"))
            } else {
                fail(L("无法采集系统声音（需要“屏幕与系统录音”权限）：", "Can't capture system audio (needs Screen & System Audio Recording permission): ") + error.localizedDescription)
            }
            sys.retryInBackground(appName: cfg.remoteApp)
        } }

        // My audio.
        let micDev = Devices.microphone(named: cfg.micName)
        mic.onBuffer = { [weak self] b in
            guard let self else { return }
            if self.cfg.passthrough { self.output?.passMic(b) }
            if rms(b) > 0.01 { self.gateLock.lock(); self.lastMicLoud = Date(); self.gateLock.unlock() }
            self.gateLock.lock(); let remoteTalking = Date().timeIntervalSince(self.lastRemoteLoud) < 0.5; let gate = self.gateOn; self.gateLock.unlock()
            if (gate && remoteTalking) || !self.model.translateMe || (self.output?.speaking ?? false) {
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
            fail(L("无法打开麦克风（需要麦克风权限）：", "Can't open the microphone (needs Microphone permission): ") + error.localizedDescription)
        } }

        refreshEnvironment()
        await MainActor.run {
            model.source = status.remoteSource == "all system audio" ? L("全部系统声音", "all system audio") : status.remoteSource.replacingOccurrences(of: "audio of ", with: "")
            model.mic = status.micDevice
            model.active = true
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
        // Not a task group: withTaskGroup waits for *every* child before returning, so a body
        // stuck in a framework call (it happens: SpeechAnalyzer finish on a silent stream) would
        // make the timeout meaningless. Race two unstructured tasks and take whichever lands first.
        let finished: Bool = await withCheckedContinuation { cont in
            let gate = OnceGate()
            Task { await body(); if gate.claim() { cont.resume(returning: true) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); if gate.claim() { cont.resume(returning: false) } }
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
        // The recognizer sometimes starts a sentence with the previous one's full stop (". Great.").
        var en = normalizeEnglish(raw).trimmingCharacters(in: .whitespaces)
        while let c = en.first, ".,;:，。、；：".contains(c) { en.removeFirst(); en = en.trimmingCharacters(in: .whitespaces) }
        guard !en.isEmpty else { return }
        Task {
            let zh = (try? await toMine.translate(en)) ?? L("（翻译失败）", "(translation failed)")
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

    /// Typed in the overlay, or posted via `hushpiece say` / MCP. Text already in the other
    /// side's language is spoken as is; anything else is translated first.
    func typed(_ text: String, translate: Bool = true) {
        Task {
            var translated = text
            let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? ""
            let alreadyRemote = translationLang(detected) == translationLang(cfg.remoteLocale)
            if translate && !alreadyRemote {
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
        ticks += 1
        if ticks % 3 == 0 { refreshEnvironment() }
    }

    /// Who is reading the virtual mic, and whether headphones decide the echo guard.
    private func refreshEnvironment() {
        let l = currentListeners()
        let gate: Bool
        switch cfg.echoGuard {
        case "on": gate = true
        case "off": gate = false
        default: gate = !Devices.headphonesActive()
        }
        gateLock.lock(); listeners = l; gateOn = gate; gateLock.unlock()
        Task { @MainActor in
            if self.model.listeners != l { self.model.listeners = l }
            if !l.isEmpty, self.model.notHeard { self.model.notHeard = false }
            if self.model.echoGuard != gate { self.model.echoGuard = gate }
        }
    }

    private func currentListeners() -> [String] {
        guard let out = output, let dev = Devices.all().first(where: { $0.name == out.deviceName }) else { return [] }
        return Devices.listeners(of: dev)
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

/// First caller wins; used to resume a continuation exactly once from racing tasks.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
