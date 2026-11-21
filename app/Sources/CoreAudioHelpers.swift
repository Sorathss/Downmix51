import CoreAudio
import Foundation

/// An output-capable audio device shown in the picker.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannels: Int
}

/// Thin wrappers around the CoreAudio HAL property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceIDs() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = addr(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = addr(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Channel count of each stream (buffer) of a device in the given scope.
    static func bufferChannelCounts(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func nominalSampleRate(_ dev: AudioObjectID) -> Double? {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    @discardableResult
    static func setNominalSampleRate(_ dev: AudioObjectID, _ rate: Double) -> OSStatus {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var r: Float64 = rate
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
    }

    /// 1-based channel numbers the device prefers for stereo output.
    static func preferredStereoChannels(_ dev: AudioObjectID) -> (Int, Int) {
        var a = addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var ch: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &ch) == noErr else { return (1, 2) }
        return (Int(ch[0]), Int(ch[1]))
    }

    static func isAlive(_ dev: AudioObjectID) -> Bool {
        (uint32(dev, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
    }

    static func deviceID(uid: String) -> AudioObjectID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        uint32(system, kAudioHardwarePropertyDefaultOutputDevice).flatMap { $0 == 0 ? nil : $0 }
    }

    @discardableResult
    static func setDefaultOutputDevice(_ dev: AudioObjectID) -> OSStatus {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var d = dev
        return AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
    }

    /// All live devices with output channels, excluding devices whose UID starts with any of `excluding`.
    static func outputDevices(excluding prefixes: [String]) -> [AudioDevice] {
        deviceIDs().compactMap { id -> AudioDevice? in
            guard isAlive(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !prefixes.contains(where: { uid.hasPrefix($0) }) else { return nil }
            let channels = bufferChannelCounts(id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +)
            guard channels > 0 else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return AudioDevice(id: id, uid: uid, name: name, outputChannels: channels)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
