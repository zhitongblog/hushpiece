import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputs: Int
    let outputs: Int
    var isVirtual: Bool { name.localizedCaseInsensitiveContains("blackhole") }
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

    static func blackHole() -> AudioDevice? {
        all().first { $0.isVirtual && $0.outputs > 0 }
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
