import AppKit
import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputs: Int
    let outputs: Int
    /// Loopback-style devices: what the meeting app should pick as its microphone.
    var isVirtual: Bool {
        ["blackhole", "hushpiece", "loopback", "soundflower", "vb-cable", "virtual"].contains { name.localizedCaseInsensitiveContains($0) }
    }
}

enum Devices {
    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioDevice(id: id,
                        name: stringProp(id, kAudioObjectPropertyName) ?? "?",
                        uid: stringProp(id, kAudioDevicePropertyDeviceUID) ?? "?",
                        inputs: channels(id, kAudioObjectPropertyScopeInput),
                        outputs: channels(id, kAudioObjectPropertyScopeOutput))
        }
    }

    /// Case-insensitive substring match on the device name.
    static func find(_ name: String, output: Bool) -> AudioDevice? {
        all().first { $0.name.localizedCaseInsensitiveContains(name) && (output ? $0.outputs > 0 : $0.inputs > 0) }
    }

    /// The virtual mic we speak into: our own driver first, then any other loopback device.
    static func blackHole() -> AudioDevice? {
        let v = all().filter { $0.isVirtual && $0.outputs > 0 && $0.inputs > 0 }
        return v.first { $0.name.localizedCaseInsensitiveContains("hushpiece") } ?? v.first
    }

    static func inputs() -> [AudioDevice] { all().filter { $0.inputs > 0 && !$0.isVirtual } }
    static func outputs() -> [AudioDevice] { all().filter { $0.outputs > 0 } }

    /// Apps (other than us) currently recording from `device` — i.e. the meeting app that picked
    /// the virtual mic. Uses the Core Audio process list (macOS 14.4+).
    static func listeners(of device: AudioDevice) -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &procs) == noErr else { return [] }
        var names: [String] = []
        for p in procs {
            var pid: pid_t = 0; var ps = UInt32(MemoryLayout<pid_t>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(p, &a, 0, nil, &ps, &pid) == noErr, pid != getpid() else { continue }
            var running: UInt32 = 0; var rs = UInt32(4)
            a.mSelector = kAudioProcessPropertyIsRunningInput
            guard AudioObjectGetPropertyData(p, &a, 0, nil, &rs, &running) == noErr, running != 0 else { continue }
            a.mSelector = kAudioProcessPropertyDevices; a.mScope = kAudioObjectPropertyScopeInput
            var ds: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(p, &a, 0, nil, &ds) == noErr, ds > 0 else { continue }
            var devs = [AudioObjectID](repeating: 0, count: Int(ds) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(p, &a, 0, nil, &ds, &devs) == noErr, devs.contains(device.id) else { continue }
            names.append(appName(pid))
        }
        return Array(Set(names)).sorted()
    }

    /// Friendly name for a pid; helper processes map to their owning app ("企业微信·会议" → as-is).
    static func appName(_ pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 1024)
        return proc_name(pid, &buf, 1024) > 0 ? String(cString: buf) : "pid \(pid)"
    }

    /// Are the user's ears on headphones? Then the mic can't hear the other side and the echo
    /// guard (pause my recognition while they talk) only costs interruptions.
    static func headphonesActive() -> Bool {
        let id = defaultDevice(input: false)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0; var size = UInt32(4)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeUSB { return true }
        // Built-in output: the data source says whether it's the speakers or the headphone jack.
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                          mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var source: UInt32 = 0; size = 4
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &source) == noErr {
            return source == 0x6864_706E   // 'hdpn'
        }
        return false
    }

    static var defaultOutputName: String {
        let id = defaultDevice(input: false)
        return all().first { $0.id == id }?.name ?? "?"
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// The real microphone: explicit name if given, else the system default input
    /// unless that is a virtual device (user may have set BlackHole as default), in which
    /// case the first physical input.
    static func microphone(named: String?) -> AudioDevice? {
        if let named { return find(named, output: false) }
        let devs = all()
        let def = defaultDevice(input: true)
        if let d = devs.first(where: { $0.id == def && $0.inputs > 0 && !$0.isVirtual }) { return d }
        return devs.first { $0.inputs > 0 && !$0.isVirtual }
    }

    private static func stringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
