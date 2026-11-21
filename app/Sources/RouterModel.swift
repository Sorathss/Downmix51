import AVFoundation
import AppKit
import CoreAudio
import Foundation
import ServiceManagement

/// UI-facing state and the app's lifecycle. Lives on the main thread.
///
/// Launch:  install driver if needed → publish the “Downmix51” device → start routing
///          → make it the system output.
/// Quit:    stop routing → give the system output back → remove the device.
final class RouterModel: ObservableObject {
    static let shared = RouterModel()

    static let minGainDB = -40.0
    static let maxGainDB = 0.0
    /// −12.04 dB = ×0.25: four full-scale channels summed can never exceed 0 dBFS.
    static let safeGainDB = 20 * log10(0.25)

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var driverState: DriverManager.State = .notInstalled
    @Published private(set) var driverBusy = false
    @Published private(set) var virtualPresent = false
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var levelL: Double = -100   // dBFS, post-gain, pre-clamp
    @Published private(set) var levelR: Double = -100
    @Published private(set) var clipping = false
    @Published private(set) var micDenied = false

    @Published var selectedUID: String {
        didSet {
            guard selectedUID != oldValue else { return }
            defaults.set(selectedUID, forKey: Keys.output)
            if enabled { start() }
        }
    }
    /// Routing on/off. Off also hands the system output back to the real device.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Keys.enabled)
            if enabled {
                requestMicrophoneThenStart()
            } else {
                stop(message: "Off")
                restoreSystemOutput()
            }
        }
    }
    /// Make “Downmix51” the system output while the app runs (restored on quit).
    @Published var takeOverSystemOutput: Bool {
        didSet {
            guard takeOverSystemOutput != oldValue else { return }
            defaults.set(takeOverSystemOutput, forKey: Keys.takeOver)
            if takeOverSystemOutput { tookOverSystemOutput = false; takeOverSystemOutputIfNeeded() }
            else { restoreSystemOutput() }
        }
    }
    /// Output volume in dB (applied after the 5.1 → stereo sum).
    @Published var gainDB: Double {
        didSet { defaults.set(gainDB, forKey: Keys.gain); applyGain() }
    }
    @Published var muted = false {
        didSet { applyGain() }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                status = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    private let engine = RouterEngine()
    private let defaults = UserDefaults.standard
    private var meterTimer: Timer?
    private var heartbeatTimer: Timer?
    private var activity: NSObjectProtocol?
    private var lastClipCount: UInt32 = 0
    private var clipHoldUntil = Date.distantPast
    private var lastStart = Date.distantPast
    private var pendingRestart: DispatchWorkItem?
    private var rateListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var tookOverSystemOutput = false
    private var previousSystemOutputUID: String?
    private var didShutdown = false

    private enum Keys {
        static let output = "outputDeviceUID"
        static let enabled = "routingEnabled"
        static let gain = "gainDB"
        static let takeOver = "takeOverSystemOutput"
    }

    private init() {
        defaults.register(defaults: [Keys.enabled: true, Keys.gain: -6.0, Keys.takeOver: true])
        selectedUID = defaults.string(forKey: Keys.output) ?? ""
        enabled = defaults.bool(forKey: Keys.enabled)
        gainDB = defaults.double(forKey: Keys.gain)
        takeOverSystemOutput = defaults.bool(forKey: Keys.takeOver)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        applyGain()

        refreshDevices()
        if selectedUID.isEmpty || !devices.contains(where: { $0.uid == selectedUID }) {
            // Default route target: whatever the system was playing to before we started.
            let current = CA.defaultOutputDevice().flatMap { id in devices.first { $0.id == id } }
            if let pick = current ?? devices.first { selectedUID = pick.uid }
        }

        // Keep timers (heartbeat) running at full rate: a menu-bar app is otherwise App-Napped.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Routing audio from the Downmix51 device")

        installSystemListeners()
        startMeterTimer()
        startHeartbeat()
        status = enabled ? "Starting…" : "Off"

        driverState = DriverManager.state()
        switch driverState {
        case .installed:
            DriverManager.setDevicePresent(true)   // device appears → devicesChanged() starts routing
            if virtualPresent { scheduleRestart(after: 0) }
        case .notInstalled, .outdated:
            DispatchQueue.main.async { self.installDriver() }
        case .bundleMissing:
            status = "Driver not found in the app bundle — rebuild with build.sh."
        }
    }

    // MARK: - Lifecycle

    /// Called on quit (menu Quit, logout, SIGTERM). Leaves the system as it was before launch.
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        heartbeatTimer?.invalidate()
        meterTimer?.invalidate()
        pendingRestart?.cancel()
        removeRateListeners()
        engine.stop()
        restoreSystemOutput()
        DriverManager.setDevicePresent(false)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    func installDriver() {
        guard !driverBusy else { return }
        driverBusy = true
        stop(message: driverState == .outdated ? "Updating driver…" : "Installing driver…")
        DriverManager.install { [weak self] result in
            guard let self else { return }
            self.driverBusy = false
            self.driverState = DriverManager.state()
            switch result {
            case .success:
                // coreaudiod restarts; the heartbeat publishes the device as soon as the driver is loaded.
                self.status = "Driver installed — starting…"
                DriverManager.setDevicePresent(true)
            case .failure(let error):
                self.status = "Driver not installed: \(error.localizedDescription)"
            }
        }
    }

    func uninstallDriverAndQuit() {
        let alert = NSAlert()
        alert.messageText = "Remove the Downmix51 audio driver?"
        alert.informativeText = "The Downmix51 device will be removed from the system and the app will quit. It will offer to install the driver again the next time you open it."
        alert.addButton(withTitle: "Remove and Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        shutdown()
        driverBusy = true
        DriverManager.uninstall { [weak self] result in
            self?.driverBusy = false
            switch result {
            case .success:
                NSApp.terminate(nil)
            case .failure(let error):
                self?.status = "Driver not removed: \(error.localizedDescription)"
                self?.didShutdown = false
                self?.startHeartbeat()
            }
        }
    }

    // MARK: - Routing

    func start() {
        guard enabled, !didShutdown, !driverBusy else { return }
        removeRateListeners()
        guard !selectedUID.isEmpty else {
            engine.stop(); isRunning = false; status = "Choose an output device"
            return
        }
        lastStart = Date()
        do {
            try engine.start(outputUID: selectedUID)
            isRunning = true
            let rate = engine.sampleRate > 0 ? String(format: " · %.0f Hz", engine.sampleRate) : ""
            status = "Running\(rate)" + (micDenied ? " · NO INPUT: allow Microphone access" : "")
            addRateListener(engine.outputDeviceID)
            addRateListener(engine.virtualDeviceID)
            takeOverSystemOutputIfNeeded()
        } catch RouterError.virtualDeviceMissing {
            isRunning = false
            status = driverState == .installed ? "Waiting for the Downmix51 device…"
                                               : RouterError.virtualDeviceMissing.localizedDescription
        } catch {
            isRunning = false
            status = error.localizedDescription
        }
    }

    func stop(message: String) {
        removeRateListeners()
        engine.stop()
        isRunning = false
        status = message
    }

    func setGainPreset(_ db: Double) { gainDB = db }

    var virtualIsSystemOutput: Bool {
        guard let virt = CA.deviceID(uid: RouterEngine.virtualDeviceUID) else { return false }
        return CA.defaultOutputDevice() == virt
    }

    func makeVirtualDeviceSystemOutput() {
        tookOverSystemOutput = false
        takeOverSystemOutputIfNeeded(force: true)
    }

    func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - System output hand-over

    /// Done once per appearance of the device, so a manual switch by the user is not fought.
    private func takeOverSystemOutputIfNeeded(force: Bool = false) {
        guard (takeOverSystemOutput || force), enabled, !tookOverSystemOutput,
              let virt = CA.deviceID(uid: RouterEngine.virtualDeviceUID) else { return }
        if let current = CA.defaultOutputDevice(), current != virt {
            previousSystemOutputUID = CA.string(current, kAudioDevicePropertyDeviceUID)
            CA.setDefaultOutputDevice(virt)
        }
        tookOverSystemOutput = true
        objectWillChange.send()
    }

    /// If the system output is our device, switch it back to what it was (or to the routed device).
    private func restoreSystemOutput() {
        tookOverSystemOutput = false
        guard let virt = CA.deviceID(uid: RouterEngine.virtualDeviceUID), CA.defaultOutputDevice() == virt else { return }
        let candidates = [previousSystemOutputUID, selectedUID].compactMap { $0 }
        if let target = candidates.lazy.compactMap({ CA.deviceID(uid: $0) }).first {
            CA.setDefaultOutputDevice(target)
        }
        objectWillChange.send()
    }

    // MARK: - Internals

    private func applyGain() {
        engine.gain = muted ? 0 : Float(pow(10, gainDB / 20))
    }

    /// Reading any input device (even a virtual one) needs Microphone permission; without it the input is silent.
    private func requestMicrophoneThenStart() {
        guard virtualPresent else { start(); return }   // no prompt until the device exists
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micDenied = false
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.micDenied = !granted
                    self.start()
                }
            }
        default:
            micDenied = true
            start()
        }
    }

    private func refreshDevices() {
        devices = CA.outputDevices(excluding: RouterEngine.ownUIDPrefixes)
        virtualPresent = CA.deviceID(uid: RouterEngine.virtualDeviceUID) != nil
    }

    /// Device list changed (plug/unplug, our device appearing/disappearing, our aggregate being created/destroyed).
    private func devicesChanged() {
        guard !didShutdown else { return }
        refreshDevices()
        if !virtualPresent { tookOverSystemOutput = false }
        if !driverBusy, driverState != .installed { driverState = DriverManager.state() }
        guard enabled else { return }
        let outputPresent = devices.contains { $0.uid == selectedUID }
        if isRunning {
            if !outputPresent || !virtualPresent || !CA.isAlive(engine.outputDeviceID) {
                stop(message: !virtualPresent ? "Waiting for the Downmix51 device…"
                                              : "Output device disconnected — waiting for it…")
            }
        } else if outputPresent && virtualPresent {
            scheduleRestart()
        }
    }

    private func scheduleRestart(after delay: TimeInterval = 0.4) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestMicrophoneThenStart() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Re-publishes the device every 2 s; the driver hides it if this stops for 10 s.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, !self.didShutdown, !self.driverBusy, self.driverState == .installed else { return }
            DriverManager.setDevicePresent(true)
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func installSystemListeners() {
        var a = CA.addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(CA.system, &a, DispatchQueue.main) { [weak self] _, _ in
            self?.devicesChanged()
        }
        var d = CA.addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &d, DispatchQueue.main) { [weak self] _, _ in
            self?.objectWillChange.send()   // refresh "is system output" hint
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.enabled else { return }
            DriverManager.setDevicePresent(true)
            self.scheduleRestart(after: 1.5)
        }
    }

    /// Sample-rate change on either device → rebuild the route (virtual device re-follows the hardware rate).
    private func addRateListener(_ dev: AudioObjectID) {
        guard dev != 0 else { return }
        var a = CA.addr(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.enabled, Date().timeIntervalSince(self.lastStart) > 1.5 else { return }
            self.scheduleRestart()
        }
        if AudioObjectAddPropertyListenerBlock(dev, &a, DispatchQueue.main, block) == noErr {
            rateListeners.append((dev, block))
        }
    }

    private func removeRateListeners() {
        for (dev, block) in rateListeners {
            var a = CA.addr(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(dev, &a, DispatchQueue.main, block)
        }
        rateListeners.removeAll()
    }

    private func startMeterTimer() {
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.updateMeters() }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func updateMeters() {
        let rt = engine.rt
        let pl = rt.pointee.peakL, pr = rt.pointee.peakR
        rt.pointee.peakL = 0
        rt.pointee.peakR = 0

        func db(_ x: Float) -> Double { x > 0.00001 ? 20 * log10(Double(x)) : -100 }
        // Instant attack, ~30 dB/s release.
        let newL = max(db(pl), levelL - 1.5), newR = max(db(pr), levelR - 1.5)
        if abs(newL - levelL) > 0.1 { levelL = newL }
        if abs(newR - levelR) > 0.1 { levelR = newR }

        let count = rt.pointee.clipCount
        if count != lastClipCount {
            lastClipCount = count
            clipHoldUntil = Date().addingTimeInterval(1.5)
        }
        let clip = Date() < clipHoldUntil
        if clip != clipping { clipping = clip }
    }
}
