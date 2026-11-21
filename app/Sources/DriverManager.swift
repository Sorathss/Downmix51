import AppKit
import CoreAudio
import Foundation

/// Installs/uninstalls the embedded HAL driver and makes its device appear/disappear.
///
/// The device is only *published* while the app holds the driver's box "acquired". The app
/// re-sends `acquired = 1` every 2 s as a heartbeat; if the heartbeat stops for 10 s (crash,
/// force quit) the driver hides the device by itself.
enum DriverManager {
    static let bundleName = "Downmix51.driver"
    static let boxUID = "Downmix51_UID"
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL").appendingPathComponent(bundleName)
    static var bundledURL: URL? { Bundle.main.resourceURL?.appendingPathComponent(bundleName) }

    enum State: Equatable {
        case notInstalled, outdated, installed
        case bundleMissing   // app was built without the driver inside
    }

    static func state() -> State {
        guard let bundled = bundledURL, FileManager.default.fileExists(atPath: bundled.path) else {
            return FileManager.default.fileExists(atPath: installedURL.path) ? .installed : .bundleMissing
        }
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return .notInstalled }
        let exe = "Contents/MacOS/Downmix51"
        let a = try? Data(contentsOf: bundled.appendingPathComponent(exe))
        let b = try? Data(contentsOf: installedURL.appendingPathComponent(exe))
        return (a != nil && a == b) ? .installed : .outdated
    }

    // MARK: Install / uninstall (admin password via the standard macOS prompt)

    static func install(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let src = bundledURL else {
            completion(.failure(DriverError.message("The driver is missing from the app bundle.")))
            return
        }
        let dir = installedURL.deletingLastPathComponent().path
        let shell = """
        set -e; mkdir -p \(q(dir)); rm -rf \(q(installedURL.path)); \
        cp -R \(q(src.path)) \(q(dir + "/")); chown -R root:wheel \(q(installedURL.path)); \
        killall coreaudiod || true
        """
        runAsAdmin(shell, prompt: "Downmix51 needs to install its audio driver (the virtual 5.1 device “Downmix51”).", completion: completion)
    }

    static func uninstall(completion: @escaping (Result<Void, Error>) -> Void) {
        let shell = "rm -rf \(q(installedURL.path)); killall coreaudiod || true"
        runAsAdmin(shell, prompt: "Downmix51 needs to remove its audio driver.", completion: completion)
    }

    enum DriverError: LocalizedError {
        case message(String)
        case cancelled
        var errorDescription: String? {
            switch self {
            case .message(let m): return m
            case .cancelled: return "Cancelled."
            }
        }
    }

    private static func runAsAdmin(_ shell: String, prompt: String,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        let script = "do shell script \"\(asEscape(shell))\" with administrator privileges with prompt \"\(asEscape(prompt))\""
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            var result: Result<Void, Error>
            do {
                try p.run()
                p.waitUntilExit()
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    result = .success(())
                } else if msg.contains("-128") {
                    result = .failure(DriverError.cancelled)
                } else {
                    result = .failure(DriverError.message(msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Single-quote for /bin/sh.
    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Escape for an AppleScript string literal.
    private static func asEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Device presence

    static func boxID() -> AudioObjectID? {
        var a = CA.addr(kAudioHardwarePropertyBoxList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(CA.system, &a, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(CA.system, &a, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { CA.string($0, kAudioBoxPropertyBoxUID) == boxUID }
    }

    /// Publish (true) or remove (false) the virtual device. Publishing again acts as the heartbeat.
    @discardableResult
    static func setDevicePresent(_ present: Bool) -> Bool {
        guard let box = boxID() else { return false }
        var a = CA.addr(kAudioBoxPropertyAcquired)
        var v: UInt32 = present ? 1 : 0
        return AudioObjectSetPropertyData(box, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
}
