# Downmix51

A menu-bar app for macOS that provides a 6-channel (5.1) virtual output device named **Downmix51** (same as the app) and mixes it down to stereo on whichever output device you choose.

```
any app ──5.1──▶ "Downmix51" device (virtual, 6ch) ──▶ Downmix51 app ──stereo──▶ your headphones / speakers
                 L R C LFE Ls Rs                       L = 1+3+4+5
                                                       R = 2+3+4+6
                                                       × volume slider
```

## How the app behaves

| When | What happens |
|---|---|
| **First launch** | The app asks for your admin password, using the standard macOS dialog, and installs its audio driver. This happens once. Then it asks for Microphone access, which macOS requires before an app can read any input device, even a virtual one. |
| **Every launch** | The **Downmix51** device appears, routing starts, and Downmix51 becomes the system output. That last step can be turned off in the menu. |
| **Quit** (Quit button, logout, `kill`) | Routing stops, the system output switches back to the device you had before, and **Downmix51 disappears**. |
| **Crash / force quit** | The driver notices the app has stopped and removes Downmix51 within about 10 seconds. |
| **App not running** | Downmix51 doesn't exist. The installed driver sits idle and shows no devices. |

### Why there's a one-time driver install

macOS has no API that lets an app create a new output device by itself. Every app that provides virtual devices installs a driver once, including Rogue Amoeba's Loopback (its `ARK.driver` is on this Mac in `/Library/Audio/Plug-Ins/HAL`). After that, the app turns its devices on and off through the driver.

Downmix51 carries its driver inside the app bundle (`Contents/Resources/Downmix51.driver`) and installs or updates it itself, so there's no install script.

## Parts

| Path | What it is |
|---|---|
| `driver/BlackHole.c` | [BlackHole](https://github.com/ExistentialAudio/BlackHole) 0.7.1 (upstream commit in `driver/UPSTREAM.txt`), changed in these ways: **6 channels** with a 5.1 layout (L R C LFE Ls Rs), device name **Downmix51**, its own bundle ID and UIDs so it can coexist with BlackHole, the device starts hidden, and a heartbeat watchdog. While the app runs, it re-acquires the driver's "box" every 2 s. If that stops for 10 s, the driver hides the device. |
| `app/Sources/` | The SwiftUI menu-bar app (macOS 13+): driver install, device lifecycle, routing engine, UI |
| `tests/e2e.swift` | End-to-end test tool, see below |
| `build.sh` | Builds `build/Downmix51.app` with the driver embedded |
| `uninstall.sh` | Removes the app and driver by hand. The app's own **More → Remove Driver and Quit…** does the same thing. |

## Build and run

You need only the Xcode Command Line Tools, not full Xcode.

```bash
./build.sh
```

```bash
cp -R build/Downmix51.app /Applications/ && open /Applications/Downmix51.app
```

After that, click the speaker icon in the menu bar:

- **Stereo output device:** your real output (headphones, speakers, USB DAC…).
- **Output volume:** −40 to 0 dB, applied after the channels are summed, so turning it down is how you prevent clipping. There's a mute button and presets for **0 dB**, **−6 dB** and **−12 dB (never clips)**. At −12 dB the gain is ×0.25, so four full-scale channels sum to exactly 0 dBFS.
- **CLIP** lights up whenever the mix goes over 0 dBFS. Anything over full scale is hard-limited to ±1.0.
- Other controls: on/off switch, "Make Downmix51 the system output while running", Launch at login, and **More → Reinstall / Remove Driver**.

When you rebuild, the app sees that its embedded driver is newer than the installed one and offers to update it.

## How the routing works

The app builds a private aggregate device, which other apps can't see, out of [chosen output (clock master), Downmix51 (drift-compensated)]. One real-time IOProc reads Downmix51's 6 loopback channels, computes L = ch1+ch3+ch4+ch5 and R = ch2+ch3+ch4+ch6, multiplies by the volume, and writes the result to the output's preferred stereo pair. A mono output gets (L+R)/2. Downmix51 always follows the hardware's sample rate; the hardware's rate is never changed.

## Tests

- **Mix routine (offline):** the render function run on synthetic buffers. It checks channel routing, gain, clamping, clip detection, mono fallback and bad-configuration handling.
- **End-to-end (real audio):** the app routes Downmix51 to a loopback device such as BlackHole 16ch. `tests/build-e2e.sh` builds `build/Downmix51Test.app`, which plays known levels into Downmix51's 6 channels and measures the stereo result.

  ```bash
  tests/build-e2e.sh && open -W build/Downmix51Test.app --args measure BlackHole16ch_UID 0 --log /tmp/e2e.txt; cat /tmp/e2e.txt
  ```

  The second argument is the app's current volume in dB.

Results on this Mac (macOS 27.2, 48 kHz):

| Check | Result |
|---|---|
| Downmix51 appears on launch: 6 in / 6 out, layout L R C LFE Ls Rs | ✅ |
| Downmix51 becomes the system output while running, and stays present (heartbeat) | ✅ |
| Downmix at 0 dB: each channel alone, all distinct, all full scale | ✅ 8/8, exact |
| Downmix at −12.04 dB: full-scale 5.1 → exactly 1.0, no clipping | ✅ 8/8, exact |
| Quit (SIGTERM): Downmix51 removed, previous system output restored | ✅ within 1 s |
| Crash (SIGKILL): Downmix51 removed by the driver's watchdog | ✅ 11 s |

## Notes

- **Signing.** The app and driver are ad-hoc signed, which is fine on your own Mac. Each rebuild changes the signature, so macOS may ask for Microphone permission again. To give the app to other people, sign it with a Developer ID and notarize it.
- **Intel Macs.** The driver is built universal. The app is built for the Mac you build on; use `APP_ARCH=x86_64 ./build.sh` to cross-build it.
- **Volume keys.** When Downmix51 is the system output, the volume keys control Downmix51's own volume, which is applied before the mix. The app's slider is applied after it.

## License

GPL-3.0 (see `LICENSE`), the same as BlackHole, which this is based on.
