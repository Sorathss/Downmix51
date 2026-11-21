import SwiftUI

@main
struct Downmix51App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RouterModel.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRunning ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Makes sure every way of quitting runs the cleanup (stop routing, restore output, remove device).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = RouterModel.shared
        ProcessInfo.processInfo.disableAutomaticTermination("Routing audio")
        ProcessInfo.processInfo.disableSuddenTermination()
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RouterModel.shared.shutdown()
    }
}

struct ContentView: View {
    @EnvironmentObject var model: RouterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.driverState != .installed { driverBanner }
            outputPicker
            volume
            meters
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("5.1 → Stereo Downmix").font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.isRunning ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: $model.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var driverBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.driverState == .outdated
                 ? "A newer version of the audio driver is included with this app."
                 : "The audio driver that provides the “Downmix51” device needs to be installed (one time, admin password).")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if model.driverState != .bundleMissing {
                Button(model.driverState == .outdated ? "Update Driver…" : "Install Driver…") { model.installDriver() }
                    .disabled(model.driverBusy)
                    .controlSize(.small)
            }
        }
    }

    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stereo output device").font(.subheadline).foregroundStyle(.secondary)
            Picker("", selection: $model.selectedUID) {
                if !model.devices.contains(where: { $0.uid == model.selectedUID }) {
                    Text(model.selectedUID.isEmpty ? "Choose…" : "Disconnected device").tag(model.selectedUID)
                }
                ForEach(model.devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()

            Toggle("Make “Downmix51” the system output while running", isOn: $model.takeOverSystemOutput)
                .font(.caption)
            if model.virtualPresent && model.isRunning && !model.virtualIsSystemOutput {
                Button("Use “Downmix51” as system output now") { model.makeVirtualDeviceSystemOutput() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output volume").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(model.muted ? "Muted" : String(format: "%.1f dB", model.gainDB))
                    .font(.system(.subheadline, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button {
                    model.muted.toggle()
                } label: {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(model.muted ? "Unmute" : "Mute")

                Slider(value: $model.gainDB, in: RouterModel.minGainDB...RouterModel.maxGainDB)
            }
            HStack(spacing: 6) {
                preset("0 dB", 0)
                preset("−6 dB", -6)
                preset("−12 dB (never clips)", RouterModel.safeGainDB)
            }
        }
    }

    private func preset(_ title: String, _ db: Double) -> some View {
        Button(title) { model.setGainPreset(db) }
            .controlSize(.small)
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 4) {
            LevelBar(label: "L", db: model.levelL)
            LevelBar(label: "R", db: model.levelR)
            HStack {
                Text("L = 1+3+4+5   R = 2+3+4+6")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("CLIP")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(model.clipping ? Color.red : Color.gray.opacity(0.2)))
                    .foregroundStyle(model.clipping ? Color.white : Color.secondary)
                    .help("Lights when the mix exceeds 0 dBFS. Lower the volume until it stays off.")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.micDenied {
                Button("Allow Microphone access (needed to read the virtual device)…") {
                    model.openMicrophoneSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .font(.caption)
            HStack {
                Button("Audio MIDI Setup…") { model.openAudioMIDISetup() }
                Menu("More") {
                    Button("Reinstall Driver…") { model.installDriver() }
                    Button("Remove Driver and Quit…") { model.uninstallDriverAndQuit() }
                }
                .fixedSize()
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .help("Stops routing, restores the system output and removes the Downmix51 device")
            }
            .controlSize(.small)
        }
    }
}

/// Horizontal peak meter, −60 … +6 dBFS.
struct LevelBar: View {
    let label: String
    let db: Double

    private static let floor = -60.0, ceiling = 6.0

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.monospaced()).frame(width: 10)
            GeometryReader { geo in
                let fraction = max(0, min(1, (db - Self.floor) / (Self.ceiling - Self.floor)))
                let zeroX = geo.size.width * (0 - Self.floor) / (Self.ceiling - Self.floor)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(db >= 0 ? Color.red : (db > -6 ? Color.yellow : Color.green))
                        .frame(width: geo.size.width * fraction)
                    Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1).offset(x: zeroX)
                }
            }
            .frame(height: 6)
        }
    }
}
