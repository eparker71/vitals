# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build / run

There is no Xcode project — the app is built directly with `swiftc` via `build.sh`.

```bash
bash build.sh            # build universal binary → ./Vitals
bash build.sh --install  # build + install LaunchAgent to auto-start at login

./Vitals &               # run (no Dock icon; lives in menu bar)
pkill Vitals             # stop
```

`build.sh` compiles `Vitals.swift` twice (arm64 + x86_64) and `lipo`s them into a universal binary. Targets macOS 12+. No tests, no linter.

Debug logs go to the unified log (subsystem `com.eric.vitals`):

```bash
log show --predicate 'subsystem == "com.eric.vitals"' --info --last 1h
```

## Architecture

Everything lives in **`Vitals.swift`** (~1.2k lines). The pieces are independent enough that splitting would be reasonable, but until then, navigate by `// MARK:` headers. Major sections:

- **`SMCReader`** — opens an `AppleSMC` `IOConnect` at init and reads sensor keys via `IOConnectCallStructMethod`. The SMC stores values in multiple formats and the same metric uses different keys / types across hardware:
  - **sp78** (Intel) — 16-bit fixed-point, big-endian. `readSP78`.
  - **flt** (Apple Silicon) — IEEE 754 float, **little-endian**. `readFlt`.
  - **fpe2** — used for fan RPM. `readFPE2`.
  - `readTemp` tries both sp78 and flt so callers don't care about the architecture.
  - `detectCoreKeys()` probes 256 `TpHH` keys (Apple Silicon clusters) and falls back to `TC1C…TC16C` (Intel cores). Runs once at startup.
- **`DiskReader`** — walks `IOBlockStorageDriver` and its children/parents in the IOService plane to pull model name, SMART status, and per-boot byte counters from the `Statistics` dict. Apple Silicon stores the model as `Model Number` on the **parent** NVMe controller; SATA / third-party NVMe expose it on the direct child as `Product Name`. Both paths are handled.
- **`DualBarGraphView`** — shared `NSView` used for the Wi-Fi (down/up) and Disk (read/write) graphs. Keeps a ~40-sample ring; top and bottom halves auto-scale independently so a tiny upload is still visible next to a huge download.
- **`CollapseHeader`** + the `addCollapsible` helper — section header that toggles between a one-line summary row and the expanded detail rows. Collapsed state persists in `UserDefaults`.
- **`AppDelegate`** — owns the status item, popover, two timers, the GPU/battery IOKit readers (inline), and all of the `refresh*` UI methods. Two timers run independently:
  - **3 s**: `refresh()` — Wi-Fi info, CPU/GPU/Memory/Fan/Battery/Power/Disk-meta.
  - **1 s**: `refreshGraphs()` — Wi-Fi bandwidth (from `getifaddrs`) and Disk I/O. The disk read is shared into `cachedDiskInfo` so the 3 s `refreshDisk` reuses it and the driver is polled at most once per second.

GPU utilization comes from `AGXAccelerator`'s `PerformanceStatistics` dict (Apple Silicon only; shows "unavailable" on Intel). Battery charge / cycles come from `AppleSmartBattery`. No `sudo`, no helper tools.

The menu-bar title is rebuilt by `updateTitle(rssi:pct:maxCoreTemp:)`, which is called by both `refreshWifi` and `refreshCPU` with the partial info each has. It keeps the last-seen values in `lastRssi` / `lastPct` / `lastMaxTemp` so partial calls don't blank the title.

## Gotchas

- **`CWInterface.ssid()` / `.bssid()` are gated behind Location Services on macOS 14+** — they return `nil` even when fully connected. The app has no Info.plist / entitlements, so it usually can't get that permission. **Do not** use `ssid() == nil` as a "disconnected" signal. Use `iface.interfaceMode() != .none` (and `rssiValue() != 0` as a backup). `ssid()` is fine for the display string (with `?? "—"` fallback).
- **Disk "bytes read/written" are per-boot, not lifetime.** `IOBlockStorageDriver`'s `Statistics` resets at every boot. The labels say "Read since boot:" / "Written since boot:" — keep them honest. True device-lifetime totals would require parsing NVMe SMART log pages.
- **No `.app` bundle.** The output is a bare Mach-O binary. There's no Info.plist, no bundle ID, no code signature, no icon in the menu bar (text only). Anything that depends on TCC permissions (Location, etc.) is fragile because there's no stable identity for the system to attach the grant to.
- **Sensor keys silently differ by hardware.** When adding new SMC keys, list multiple candidates and try each (see `gpuTemperature`, `memoryTemperature`, `storageTemperature`, `cpuPowerWatts`, `systemPowerWatts` for the pattern). `Tp**` for Apple Silicon thermal clusters, `TC*` for Intel cores, etc.
- **Temperature unit default is Fahrenheit.** Persisted in `UserDefaults` under the key `useCelsius` (default false). The checkbox label is "Use Celsius". Don't reintroduce the old `useFahrenheit` key.
- **The compiled `Vitals` binary is gitignored.** `bash build.sh` produces it locally; it is not committed.
