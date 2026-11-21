// End-to-end test for the Downmix51 virtual device + app.
//
//   swiftc -O tests/e2e.swift -o build/e2e
//   build/e2e devices                              list devices, show Downmix51 format/layout
//   build/e2e measure <captureUID> <gainDB>        play known levels into Downmix51's 6 channels and
//                                                  measure the stereo result on a loopback device
//   build/e2e setdefault <uid>                     set the system output device
//
// For `measure`, the app must be routing Downmix51 → <captureUID> (e.g. BlackHole16ch_UID),
// and this tool needs Microphone permission to read that loopback device.
import CoreAudio
import Foundation

let virtualUID = "Downmix51_UID"

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: el)
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}
func str(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); var v: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(o, &a, 0, nil, &size, $0) }
    return st == noErr ? (v!.takeRetainedValue() as String) : "?"
}
func channels(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
    AudioObjectGetPropertyData(d, &a, 0, nil, &size, raw)
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
}
func rate(_ d: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate); var r: Float64 = 0; var size = UInt32(8)
    AudioObjectGetPropertyData(d, &a, 0, nil, &size, &r); return r
}
func volume(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Float {
    var a = addr(kAudioDevicePropertyVolumeScalar, scope); var v: Float32 = 1; var size = UInt32(4)
    return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr ? v : 1
}
func defaultOutput() -> AudioObjectID {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var d: AudioObjectID = 0; var size = UInt32(4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &d); return d
}
func find(_ uid: String) -> AudioObjectID? { devices().first { str($0, kAudioDevicePropertyDeviceUID) == uid } }

func listDevices() {
    let def = defaultOutput()
    for d in devices() {
        print(String(format: "%@ %-28@ uid=%-40@ in=%@ out=%@ %.0fHz",
                     d == def ? "*" : " ", str(d, kAudioObjectPropertyName) as NSString,
                     str(d, kAudioDevicePropertyDeviceUID) as NSString,
                     channels(d, kAudioObjectPropertyScopeInput).description as NSString,
                     channels(d, kAudioObjectPropertyScopeOutput).description as NSString, rate(d)))
    }
    guard let b = find(virtualUID) else { print("Downmix51: NOT PRESENT"); return }
    var a = addr(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(b, &a, 0, nil, &size)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
    AudioObjectGetPropertyData(b, &a, 0, nil, &size, raw)
    let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
    let n = Int(layout.pointee.mNumberChannelDescriptions)
    let descs = withUnsafePointer(to: &layout.pointee.mChannelDescriptions) {
        UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: AudioChannelDescription.self), count: n)
    }
    let names: [AudioChannelLabel: String] = [1: "L", 2: "R", 3: "C", 4: "LFE", 5: "Ls", 6: "Rs"]
    print("Downmix51: name=\(str(b, kAudioObjectPropertyName)) layout=\(descs.map { names[$0.mChannelLabel] ?? "\($0.mChannelLabel)" })")
}

// MARK: measure

struct Pattern { let name: String; let ch: [Float] }
let patterns = [
    Pattern(name: "distinct levels", ch: [0.1, 0.2, 0.03, 0.004, 0.0005, 0.00006]),
    Pattern(name: "only ch1 (L)", ch: [0.5, 0, 0, 0, 0, 0]),
    Pattern(name: "only ch2 (R)", ch: [0, 0.5, 0, 0, 0, 0]),
    Pattern(name: "only ch3 (C)", ch: [0, 0, 0.5, 0, 0, 0]),
    Pattern(name: "only ch4 (LFE)", ch: [0, 0, 0, 0.5, 0, 0]),
    Pattern(name: "only ch5 (Ls)", ch: [0, 0, 0, 0, 0.5, 0]),
    Pattern(name: "only ch6 (Rs)", ch: [0, 0, 0, 0, 0, 0.5]),
    Pattern(name: "all full scale", ch: [1, 1, 1, 1, 1, 1]),
]

func measure(captureUID: String, gainDB: Double) -> Bool {
    guard let virt = find(virtualUID) else { print("FAIL Downmix51 device not present"); return false }
    guard let cap = find(captureUID) else { print("FAIL capture device \(captureUID) not found"); return false }
    let gain = Float(pow(10, gainDB / 20))
    let volB = volume(virt, kAudioObjectPropertyScopeOutput), volC = volume(cap, kAudioObjectPropertyScopeOutput)
    print(String(format: "Downmix51 %.0f Hz vol %.3f · capture %.0f Hz vol %.3f · app gain %.2f dB",
                 rate(virt), volB, rate(cap), volC, gainDB))
    let capIn = channels(cap, kAudioObjectPropertyScopeInput)
    guard capIn.first.map({ $0 >= 2 }) == true else { print("FAIL capture device has no stereo input"); return false }

    // Shared state (main thread writes `current`, IO threads read/write the rest).
    let current = UnsafeMutablePointer<Int32>.allocate(capacity: 1); current.pointee = 0
    let maxFrames = 48000 * 4 * 40
    let rec = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2); rec.initialize(repeating: 0, count: maxFrames * 2)
    let recCount = UnsafeMutablePointer<Int>.allocate(capacity: 1); recCount.pointee = 0
    let levels = UnsafeMutablePointer<Float>.allocate(capacity: patterns.count * 6)
    for (i, p) in patterns.enumerated() { for c in 0..<6 { levels[i * 6 + c] = p.ch[c] } }

    var playProc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&playProc, virt, nil) { _, _, _, out, _ in
        let bufs = UnsafeMutableAudioBufferListPointer(out)
        let lv = levels + Int(current.pointee) * 6
        for b in bufs {
            let n = Int(b.mNumberChannels); guard n > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(b.mDataByteSize) / (4 * n)
            for f in 0..<frames { for c in 0..<n { d[f * n + c] = c < 6 ? lv[c] : 0 } }
        }
    }
    var capProc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&capProc, cap, nil) { _, input, _, _, _ in
        let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let b = bufs.first, let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
        let n = Int(b.mNumberChannels), frames = Int(b.mDataByteSize) / (4 * n)
        for f in 0..<frames where recCount.pointee < maxFrames {
            rec[recCount.pointee * 2] = d[f * n]; rec[recCount.pointee * 2 + 1] = d[f * n + 1]; recCount.pointee += 1
        }
    }
    AudioDeviceStart(cap, capProc); AudioDeviceStart(virt, playProc)

    var windows: [(Int, Int)] = []
    Thread.sleep(forTimeInterval: 0.5)
    for i in 0..<patterns.count {
        current.pointee = Int32(i)
        let s = recCount.pointee
        Thread.sleep(forTimeInterval: 1.5)
        let e = recCount.pointee
        windows.append((s + (e - s) / 2, e))   // last half: past latency and resampler settling
    }
    AudioDeviceStop(virt, playProc); AudioDeviceStop(cap, capProc)
    AudioDeviceDestroyIOProcID(virt, playProc!); AudioDeviceDestroyIOProcID(cap, capProc!)

    if recCount.pointee == 0 { print("FAIL nothing captured"); return false }
    var allZero = true
    for i in 0..<recCount.pointee * 2 where rec[i] != 0 { allZero = false; break }
    if allZero { print("FAIL capture is all zeros (app not routing, or this tool lacks Microphone permission)"); return false }

    func median(_ xs: [Float]) -> Float { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    var ok = true
    for (i, p) in patterns.enumerated() {
        let (s, e) = windows[i]
        let l = median((s..<e).map { rec[$0 * 2] }), r = median((s..<e).map { rec[$0 * 2 + 1] })
        let c = p.ch
        let expL = min(1, (c[0] + c[2] + c[3] + c[4]) * gain) * volB * volC
        let expR = min(1, (c[1] + c[2] + c[3] + c[5]) * gain) * volB * volC
        let pass = abs(l - expL) <= max(0.002, expL * 0.01) && abs(r - expR) <= max(0.002, expR * 0.01)
        ok = ok && pass
        print(String(format: "%@ %-16@ L=%.5f (exp %.5f)  R=%.5f (exp %.5f)",
                     pass ? "PASS" : "FAIL", p.name as NSString, l, expL, r, expR))
    }
    return ok
}

var args = CommandLine.arguments
// `--log <file>`: write output to a file (used when launched as an .app via `open`).
if let i = args.firstIndex(of: "--log"), i + 1 < args.count {
    freopen(args[i + 1], "w", stdout); setvbuf(stdout, nil, _IOLBF, 0)
    args.removeSubrange(i...(i + 1))
}
switch args.count > 1 ? args[1] : "" {
case "devices": listDevices()
case "setdefault" where args.count >= 3:   // restore the system output after a crash test
    guard let d = find(args[2]) else { print("not found"); exit(1) }
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var v = d
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &v)
    print("default output -> \(str(d, kAudioObjectPropertyName))")
case "measure" where args.count >= 4:
    exit(measure(captureUID: args[2], gainDB: Double(args[3]) ?? 0) ? 0 : 1)
default:
    print("usage: e2e devices | e2e measure <captureUID> <gainDB> | e2e setdefault <uid>")
}

