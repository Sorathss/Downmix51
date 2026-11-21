import CoreAudio
import Foundation

/// State shared between the UI thread and the real-time IO thread.
/// Only plain 32-bit fields: no locks, no allocation on the audio thread.
struct RTState {
    var gain: Float = 0.5          // linear post-mix gain (volume slider / mute)
    var inBuf: Int32 = -1          // index of the 6ch virtual-device buffer in the aggregate input list
    var outBufL: Int32 = -1        // aggregate output buffer + channel for stereo Left
    var outChL: Int32 = 0
    var outBufR: Int32 = -1        // ... and stereo Right
    var outChR: Int32 = 0
    var peakL: Float = 0           // post-gain peaks, read & reset by the UI
    var peakR: Float = 0
    var clipCount: UInt32 = 0      // incremented whenever a sample had to be clamped
}

enum RouterError: LocalizedError {
    case virtualDeviceMissing
    case outputDeviceMissing
    case noOutputChannels
    case aggregateFailed(OSStatus)
    case aggregateNotReady
    case ioProcFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .virtualDeviceMissing: return "The Downmix51 virtual device is not available."
        case .outputDeviceMissing: return "Selected output device is not connected."
        case .noOutputChannels: return "Selected device has no output channels."
        case .aggregateFailed(let s): return "Could not create routing device (error \(s))."
        case .aggregateNotReady: return "Routing device did not become ready."
        case .ioProcFailed(let s): return "Could not start audio (error \(s))."
        }
    }
}

/// Routes the 6-channel virtual device to a stereo output device.
///
/// A private aggregate device is built from [output device (clock master), virtual device
/// (drift compensated)], so CoreAudio keeps the two clocks in sync. One IOProc on the
/// aggregate reads the virtual device's 6 input channels and writes the stereo downmix:
///   L = ch1 + ch3 + ch4 + ch5    (L + C + LFE + Ls)
///   R = ch2 + ch3 + ch4 + ch6    (R + C + LFE + Rs)
final class RouterEngine {
    static let virtualDeviceUID = "Downmix51_UID"
    /// UIDs to hide from the output list (our virtual device, its hidden mirror, our aggregates).
    static let ownUIDPrefixes = ["Downmix51_", "local.downmix51."]

    let rt: UnsafeMutablePointer<RTState>
    private(set) var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0
    private(set) var outputDeviceID: AudioObjectID = 0
    private(set) var virtualDeviceID: AudioObjectID = 0

    init() {
        rt = .allocate(capacity: 1)
        rt.initialize(to: RTState())
    }

    deinit {
        stop()
        rt.deinitialize(count: 1)
        rt.deallocate()
    }

    var gain: Float {
        get { rt.pointee.gain }
        set { rt.pointee.gain = newValue }
    }

    func start(outputUID: String) throws {
        stop()

        guard let virt = CA.deviceID(uid: Self.virtualDeviceUID) else { throw RouterError.virtualDeviceMissing }
        guard let out = CA.deviceID(uid: outputUID) else { throw RouterError.outputDeviceMissing }

        // The virtual device follows the hardware's sample rate (the hardware is never changed).
        if let outRate = CA.nominalSampleRate(out), CA.nominalSampleRate(virt) != outRate {
            CA.setNominalSampleRate(virt, outRate)
            waitUntil { CA.nominalSampleRate(virt) == outRate }
        }

        let outInputBufs = CA.bufferChannelCounts(out, scope: kAudioObjectPropertyScopeInput)
        let outOutputBufs = CA.bufferChannelCounts(out, scope: kAudioObjectPropertyScopeOutput)
        guard outOutputBufs.reduce(0, +) > 0 else { throw RouterError.noOutputChannels }

        // Map the device's preferred stereo pair onto (buffer, channel) positions.
        let (prefL, prefR) = CA.preferredStereoChannels(out)
        let left = Self.locate(channel: prefL, in: outOutputBufs) ?? Self.locate(channel: 1, in: outOutputBufs)!
        let right = Self.locate(channel: prefR, in: outOutputBufs)
            ?? Self.locate(channel: 2, in: outOutputBufs)
            ?? left // mono device: both sides go to channel 1 (averaged in render)

        // Build a private aggregate: output device first (clock master), virtual device second.
        let aggUID = "local.downmix51.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Downmix51 Router",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
                [kAudioSubDeviceUIDKey: Self.virtualDeviceUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var agg: AudioObjectID = 0
        let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard createStatus == noErr, agg != 0 else { throw RouterError.aggregateFailed(createStatus) }
        aggregateID = agg

        // Wait for the aggregate to expose the virtual device's 6-channel input stream.
        var inIndex = -1
        waitUntil(timeout: 2.0) {
            let bufs = CA.bufferChannelCounts(agg, scope: kAudioObjectPropertyScopeInput)
            if outInputBufs.count < bufs.count, bufs[outInputBufs.count] == 6 {
                inIndex = outInputBufs.count
            } else if let last = bufs.lastIndex(of: 6) {
                inIndex = last
            }
            let outs = CA.bufferChannelCounts(agg, scope: kAudioObjectPropertyScopeOutput)
            return inIndex >= 0 && outs.count >= outOutputBufs.count
        }
        guard inIndex >= 0 else { stop(); throw RouterError.aggregateNotReady }

        rt.pointee.inBuf = Int32(inIndex)
        rt.pointee.outBufL = Int32(left.buffer)
        rt.pointee.outChL = Int32(left.channel)
        rt.pointee.outBufR = Int32(right.buffer)
        rt.pointee.outChR = Int32(right.channel)
        rt.pointee.peakL = 0
        rt.pointee.peakR = 0

        let state = rt
        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inInput, _, outOutput, _ in
            RouterEngine.render(state, inInput, outOutput)
        }
        guard procStatus == noErr, let p = proc else { stop(); throw RouterError.ioProcFailed(procStatus) }
        procID = p

        let startStatus = AudioDeviceStart(agg, p)
        guard startStatus == noErr else { stop(); throw RouterError.ioProcFailed(startStatus) }

        outputDeviceID = out
        virtualDeviceID = virt
        sampleRate = CA.nominalSampleRate(agg) ?? 0
        isRunning = true
    }

    func stop() {
        if let p = procID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            procID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        rt.pointee.inBuf = -1
        rt.pointee.peakL = 0
        rt.pointee.peakR = 0
        isRunning = false
        sampleRate = 0
        outputDeviceID = 0
        virtualDeviceID = 0
    }

    // MARK: - Real-time render (audio thread: no locks, no allocation, no Objective-C)

    static func render(_ s: UnsafeMutablePointer<RTState>,
                       _ input: UnsafePointer<AudioBufferList>,
                       _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for b in outs where b.mData != nil {
            memset(b.mData!, 0, Int(b.mDataByteSize))
        }

        let inIdx = Int(s.pointee.inBuf)
        let lb = Int(s.pointee.outBufL), lc = Int(s.pointee.outChL)
        let rb = Int(s.pointee.outBufR), rc = Int(s.pointee.outChR)
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard inIdx >= 0, inIdx < ins.count, lb >= 0, lb < outs.count, rb >= 0, rb < outs.count else { return }

        let ib = ins[inIdx]
        guard ib.mNumberChannels == 6, let srcRaw = ib.mData,
              let lRaw = outs[lb].mData, let rRaw = outs[rb].mData else { return }

        let lStride = Int(outs[lb].mNumberChannels), rStride = Int(outs[rb].mNumberChannels)
        guard lc < lStride, rc < rStride else { return }

        let src = srcRaw.assumingMemoryBound(to: Float.self)
        let lDst = lRaw.assumingMemoryBound(to: Float.self)
        let rDst = rRaw.assumingMemoryBound(to: Float.self)

        let frames = min(Int(ib.mDataByteSize) / (6 * 4),
                         Int(outs[lb].mDataByteSize) / (lStride * 4),
                         Int(outs[rb].mDataByteSize) / (rStride * 4))
        let mono = (lb == rb && lc == rc)
        let g = s.pointee.gain

        var peakL: Float = 0, peakR: Float = 0
        var clipped: UInt32 = 0

        for f in 0..<frames {
            let p = src + f * 6
            let common = p[2] + p[3]                 // ch3 (C) + ch4 (LFE) go to both sides
            var l = (p[0] + common + p[4]) * g       // ch1 + ch3 + ch4 + ch5
            var r = (p[1] + common + p[5]) * g       // ch2 + ch3 + ch4 + ch6

            let al = abs(l), ar = abs(r)
            if al > peakL { peakL = al }
            if ar > peakR { peakR = ar }
            if al > 1 { l = l > 0 ? 1 : -1; clipped &+= 1 }
            if ar > 1 { r = r > 0 ? 1 : -1; clipped &+= 1 }

            if mono {
                lDst[f * lStride + lc] = (l + r) * 0.5
            } else {
                lDst[f * lStride + lc] = l
                rDst[f * rStride + rc] = r
            }
        }

        if peakL > s.pointee.peakL { s.pointee.peakL = peakL }
        if peakR > s.pointee.peakR { s.pointee.peakR = peakR }
        if clipped > 0 { s.pointee.clipCount &+= 1 }
    }

    // MARK: - Helpers

    /// Converts a 1-based device channel number to (buffer index, channel within buffer).
    static func locate(channel: Int, in buffers: [Int]) -> (buffer: Int, channel: Int)? {
        guard channel >= 1 else { return nil }
        var c = channel - 1
        for (i, n) in buffers.enumerated() {
            if c < n { return (i, c) }
            c -= n
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval = 1.0, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
