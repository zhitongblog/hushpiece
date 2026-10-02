import AVFoundation
import Foundation
import Speech
import Translation

// MARK: - Streaming speech-to-text (on-device SpeechAnalyzer)

final class StreamTranscriber {
    let locale: Locale
    var onVolatile: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale) { self.locale = locale }

    /// Rejects noise and silence hallucinations ("you", ", , ,") that don't match the locale's script.
    func fits(_ text: String) -> Bool {
        guard isMeaningful(text) else { return false }
        return matchesScript(text, lang: locale.identifier)
    }

    /// Locales this process is actively transcribing; never released.
    nonisolated(unsafe) private static var inUse = Set<String>()
    private static let inUseLock = NSLock()

    /// macOS lets one app hold at most `maximumReservedLocales` (5) speech locales. Switching
    /// language pairs over time fills that up ("Too many allocated locales"), so release the
    /// ones no live transcriber is using before taking a new one.
    static func makeRoom(for locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        let id = locale.identifier(.bcp47)
        guard !reserved.contains(where: { $0.identifier(.bcp47) == id }),
              reserved.count >= AssetInventory.maximumReservedLocales else { return }
        inUseLock.lock(); let keep = inUse; inUseLock.unlock()
        for r in reserved where !keep.contains(r.identifier(.bcp47)) {
            let ok = await AssetInventory.release(reservedLocale: r)
            Log.info("released speech locale \(r.identifier(.bcp47)) to make room for \(id): \(ok)")
            if await AssetInventory.reservedLocales.count < AssetInventory.maximumReservedLocales { break }
        }
    }

    static func ensureAssets(_ locale: Locale) async throws {
        await makeRoom(for: locale)
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            Log.info("ensuring speech model for \(locale.identifier)…")
            try await req.downloadAndInstall()
        }
    }

    func start() async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw NSError(domain: "calltrans", code: 1, userInfo: [NSLocalizedDescriptionKey: "speech locale \(locale.identifier) not supported"])
        }
        let transcriber = SpeechTranscriber(locale: supported,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        Self.inUseLock.lock(); Self.inUse.insert(supported.identifier(.bcp47)); Self.inUseLock.unlock()
        try await Self.ensureAssets(supported)
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        continuation = cont
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if ProcessInfo.processInfo.environment["CALLTRANS_DEBUG"] != nil {
                        Log.info("asr \(self?.locale.identifier ?? "") \(r.isFinal ? "FINAL" : "vol") [\(r.range.start.seconds)-\(r.range.end.seconds)] \(text)")
                    }
                    if r.isFinal {
                        if let self, self.fits(text) { self.onFinal?(text) }
                        self?.onVolatile?("")
                    } else if isMeaningful(text) {
                        self?.onVolatile?(text)
                    }
                }
            } catch {
                Log.info("transcriber \(self?.locale.identifier ?? "") results ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        Log.info("transcriber \(supported.identifier) ready, format \(analyzerFormat?.description ?? "?")")
    }

    /// Thread-safe; called from audio threads.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let cont = continuation, let fmt = analyzerFormat else { return }
        if buffer.format == fmt {
            cont.yield(AnalyzerInput(buffer: buffer)); return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fmt)
            converter?.primeMethod = .none
        }
        guard let conv = converter else { return }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    /// Endpointing: commit whatever has been heard so far as a final result.
    func forceFinalize() async {
        let t0 = Date()
        do { try await analyzer?.finalize(through: nil) } catch { Log.info("finalize \(locale.identifier) failed: \(error)") }
        if ProcessInfo.processInfo.environment["CALLTRANS_DEBUG"] != nil {
            Log.info("finalize \(locale.identifier) took \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }

    private func takeContinuation() -> AsyncStream<AnalyzerInput>.Continuation? {
        lock.lock(); defer { lock.unlock() }
        let c = continuation; continuation = nil; return c
    }

    func finish() async {
        takeContinuation()?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }
}

// MARK: - On-device translation

actor Translator {
    let source: Locale.Language
    let target: Locale.Language
    private let fidelity: Bool
    private var session: TranslationSession?

    init(from: String, to: String, highFidelity: Bool = true) {
        source = Locale.Language(identifier: from)
        target = Locale.Language(identifier: to)
        fidelity = highFidelity
    }

    static func isInstalled(from: String, to: String) async -> Bool {
        await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to)) == .installed
    }

    /// Retries with a fresh session: the translation daemon occasionally drops a request
    /// (seen right after coreaudiod restarts / on cold start). Later attempts use the
    /// low-latency model so one bad request can't stall a live call.
    func translate(_ text: String) async throws -> String {
        var lastError: Error?
        for attempt in 0..<3 {
            if session == nil {
                if #available(macOS 26.4, *) {
                    session = TranslationSession(installedSource: source, target: target,
                                                 preferredStrategy: fidelity && attempt == 0 ? .highFidelity : .lowLatency)
                } else {
                    session = TranslationSession(installedSource: source, target: target)
                }
            }
            do {
                let out = try await session!.translate(text).targetText
                if attempt > 0 { session = nil }  // go back to the preferred strategy next time
                return out
            } catch {
                session = nil
                lastError = error
                Log.info("translate \(source.minimalIdentifier)→\(target.minimalIdentifier) attempt \(attempt + 1) failed: \(error)")
                try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            }
        }
        throw lastError!
    }
}

// MARK: - English text-to-speech rendered to PCM buffers

final class Voice {
    let synth = AVSpeechSynthesizer()
    let voice: AVSpeechSynthesisVoice?
    let rate: Float

    init(language: String, name: String?, rate: Double) {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        if let name, let v = all.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            voice = v
        } else {
            // Prefer premium > enhanced > Daniel (the classic en-GB voice) > anything.
            voice = all.max { a, b in
                (a.quality.rawValue, a.name == "Daniel" ? 1 : 0) < (b.quality.rawValue, b.name == "Daniel" ? 1 : 0)
            } ?? AVSpeechSynthesisVoice(language: language)
        }
        self.rate = Float(rate)
    }

    /// Renders `text` to PCM buffers. Completes with all buffers.
    func render(_ text: String) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        return await withCheckedContinuation { cont in
            var buffers: [AVAudioPCMBuffer] = []
            var done = false
            synth.write(utterance) { buf in
                guard !done else { return }
                guard let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true; cont.resume(returning: buffers); return
                }
                buffers.append(pcm)
            }
        }
    }
}

func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
    let n = Int(buffer.frameLength)
    var sum: Float = 0
    for c in 0..<Int(buffer.format.channelCount) {
        let p = ch[c]
        for i in 0..<n { sum += p[i] * p[i] }
    }
    return (sum / Float(n * Int(buffer.format.channelCount))).squareRoot()
}
