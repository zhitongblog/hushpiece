import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

// MARK: - What the other side says: system audio via ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "calltrans.sysaudio", qos: .userInteractive)
    private(set) var description_ = "system audio"
    private var appName: String?
    private var stopping = false

    /// - Parameter appName: if set, only capture audio from apps whose name contains it (e.g. "WeChat").
    func start(appName: String?) async throws {
        self.appName = appName
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "calltrans", code: 2, userInfo: [NSLocalizedDescriptionKey: "no display for ScreenCaptureKit"])
        }
        let filter: SCContentFilter
        if let appName {
            let apps = content.applications.filter {
                $0.applicationName.localizedCaseInsensitiveContains(appName) || $0.bundleIdentifier.localizedCaseInsensitiveContains(appName)
            }
            guard !apps.isEmpty else {
                throw NSError(domain: "calltrans", code: 3, userInfo: [NSLocalizedDescriptionKey: "no running app matches '\(appName)'"])
            }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            description_ = "audio of " + apps.map(\.applicationName).joined(separator: ", ")
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            description_ = "all system audio"
        }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 3
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async { stopping = true; try? await stream?.stopCapture() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let pcm = sb.pcmBuffer() else { return }
        onBuffer?(pcm)
    }

    /// The stream dies if the user clicks "stop" on the menu-bar recording indicator or the
    /// capture daemon hiccups. Losing the other side's subtitles mid-call is the worst failure,
    /// so reconnect until it works (or we're shutting down).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("system audio capture stopped: \(error)")
        self.stream = nil
        reconnect(attempt: 1)
    }

    /// Test hook (SIGUSR1): kill the stream the same way the menu-bar "stop" does, then go
    /// through the normal didStopWithError path.
    func simulateInterruption() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        stream(s, didStopWithError: NSError(domain: "calltrans.test", code: -3817,
                                            userInfo: [NSLocalizedDescriptionKey: "simulated user stop"]))
    }

    private func reconnect(attempt: Int) {
        guard !stopping else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + min(Double(attempt), 5)) { [weak self] in
            guard let self, !self.stopping else { return }
            Task {
                do {
                    try await self.start(appName: self.appName)
                    Log.info("system audio capture reconnected (attempt \(attempt))")
                } catch {
                    Log.info("system audio reconnect attempt \(attempt) failed: \(error)")
                    self.reconnect(attempt: attempt + 1)
                }
            }
        }
    }
}

extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription,
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let fmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }
}

// MARK: - What I say: microphone

final class MicCapture {
    let engine = AVAudioEngine()
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(device: AudioDevice?) throws {
        let input = engine.inputNode
        if let device { try input.auAudioUnit.setDeviceID(device.id) }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            throw NSError(domain: "calltrans", code: 4, userInfo: [NSLocalizedDescriptionKey: "microphone unavailable (permission denied?)"])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.onBuffer?(buf) }
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.inputNode.removeTap(onBus: 0); engine.stop() }
}

// MARK: - What the other side hears: virtual mic (BlackHole) fed with my voice + English TTS

final class CallOutput {
    let engine = AVAudioEngine()
    let tts = AVAudioPlayerNode()
    let mic = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let deviceName: String
    var micVolume: Float = 1.0
    var duckVolume: Float = 0.15

    private var micConverter: AVAudioConverter?
    private var ttsConverters: [String: AVAudioConverter] = [:]
    private let lock = NSLock()
    private var micQueuedFrames: Int64 = 0
    private(set) var speaking = false

    init(device: AudioDevice) throws {
        deviceName = device.name
        try engine.outputNode.auAudioUnit.setDeviceID(device.id)
        engine.attach(tts)
        engine.attach(mic)
        engine.connect(tts, to: engine.mainMixerNode, format: format)
        engine.connect(mic, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        tts.play()
        mic.play()
    }

    /// Pass my live voice through to the call. Drops audio if the queue grows (clock drift).
    func passMic(_ buffer: AVAudioPCMBuffer) {
        guard let out = convert(buffer, cache: &micConverter) else { return }
        lock.lock()
        if micQueuedFrames > Int64(format.sampleRate * 0.4) { lock.unlock(); return }
        micQueuedFrames += Int64(out.frameLength)
        lock.unlock()
        mic.scheduleBuffer(out) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.micQueuedFrames -= Int64(out.frameLength); self.lock.unlock()
        }
    }

    /// Plays TTS buffers into the call; returns when playback finishes.
    func play(_ buffers: [AVAudioPCMBuffer]) async {
        let converted = buffers.compactMap { b -> AVAudioPCMBuffer? in
            let key = b.format.description
            var c = ttsConverters[key]
            defer { ttsConverters[key] = c }
            return convert(b, cache: &c)
        }
        guard !converted.isEmpty else { return }
        speaking = true
        mic.volume = duckVolume
        for (i, b) in converted.enumerated() {
            if i == converted.count - 1 {
                _ = await tts.scheduleBuffer(b, completionCallbackType: .dataPlayedBack)
            } else {
                tts.scheduleBuffer(b, completionHandler: nil)
            }
        }
        mic.volume = micVolume
        speaking = false
    }

    func stop() { engine.stop() }

    private func convert(_ buffer: AVAudioPCMBuffer, cache: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if cache == nil || cache?.inputFormat != buffer.format {
            cache = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let conv = cache else { return nil }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }
}

// MARK: - Audio file → buffers in (optionally) real time, for tests and replays

enum FileSource {
    static func stream(_ url: URL, realtime: Bool, chunk: AVAudioFrameCount = 4800, _ body: (AVAudioPCMBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: min(chunk, AVAudioFrameCount(file.length - file.framePosition)))
            if buf.frameLength == 0 { break }
            body(buf)
            if realtime { Thread.sleep(forTimeInterval: Double(buf.frameLength) / fmt.sampleRate) }
        }
    }

    /// A buffer of silence, used to keep the recognizer's timeline moving while gated.
    static func silence(like b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let s = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        s.frameLength = b.frameLength
        let abl = UnsafeMutableAudioBufferListPointer(s.mutableAudioBufferList)
        for buf in abl { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
        return s
    }
}
