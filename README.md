# Vitals

A lightweight macOS menu bar dashboard showing real system stats — Wi-Fi signal, CPU/GPU temps, fan speed, battery health, disk activity, and power draw — all from a single menu bar item with no Dock icon. Works on both Intel and Apple Silicon Macs.

## Menu bar

Updates every 3 seconds (graphs update every 1 second):

```
-56 dBm (57%) ■■■■■■□□□□ │ 52°C
```

- **Wi-Fi**: RSSI in dBm, percentage, color meter
- **CPU**: hottest core/cluster temperature
- Meter squares are color-coded: red → yellow → green (Wi-Fi signal) / green → yellow → red (heat)

## Panel (click status bar item to open/close)

The panel stays open when you click other apps — it closes only when you click the status bar item again or press **Close**. The panel automatically resizes as sections are expanded or collapsed.

Sections marked **▼** are collapsible — click the header to collapse to a single summary row, click again to expand. Collapsed state persists across restarts.

**Apple Silicon** (M-series — cluster-level sensors):
```
  ▼ Wi-Fi                          ← click to collapse (shows SSID + signal meter)
  SSID:      MyNetwork
  Signal:    -56 dBm  (57%) ■■■■■■□□□□
  Noise:     -88 dBm
  SNR:       32 dB  (excellent)
  Channel:   153  5 GHz
  TX Rate:   243 Mbps
  Security:  WPA2
  Download:  12.3 MB/s
  Upload:    524 KB/s
  [download/upload bar graph]
  ───────────────────────────
  ▼ CPU                            ← click to collapse (shows hottest temp + meter)
  Cluster 1: 46°C (23%) ■■□□□□□□□□
  Cluster 2: 45°C (21%) ■■□□□□□□□□
  Cluster 3: 44°C (20%) ■■□□□□□□□□
  ───────────────────────────
  ▼ GPU                            ← click to collapse (shows temp + meter)
  Temp:      42°C (17%) ■■□□□□□□□□
  Device:    13% ■■□□□□□□□□
  Renderer:  13% ■■□□□□□□□□
  Tiler:      9% ■□□□□□□□□□
  ───────────────────────────
  Memory
  Temp:      unavailable
  ───────────────────────────
  Fan
  Speed:     unavailable
  ───────────────────────────
  ▼ Battery                        ← click to collapse (shows charge + meter)
  Temp:      84°F (30%) ■■■□□□□□□□
  Cycle count: 12
  Charge:    100% ■■■■■■■■■■
  ───────────────────────────
  Power
  CPU package:   9.0 W
  System total:  9.8 W
  ───────────────────────────
  ▼ Disk                           ← click to collapse (hides text rows, graph stays)
  Drive:      APPLE SSD AP0512Z
  S.M.A.R.T.: Verified
  Temp:       77°F (12%) ■□□□□□□□□□
  [read/write bar graph]
  Lifetime read:    26 GB
  Lifetime written: 9 GB
  ───────────────────────────
  [✓] Use Fahrenheit
  ───────────────────────────
  [ Close ]  [ Quit ]
```

**Intel** (per-core sensors, fan, memory temp):
```
  CPU
  Core 1:    58°C (40%) ■■■■□□□□□□
  Core 2:    54°C (34%) ■■■■□□□□□□
  ───────────────────────────
  Memory
  Temp:      43°C (19%) ■■□□□□□□□□
  ───────────────────────────
  Fan
  Speed:     2200 RPM (35%) ■■■■□□□□□□
```

Sensors are detected dynamically at startup — the app adapts to whatever the SMC exposes. Sections with no available sensor show "unavailable" rather than disappearing.

## Wi-Fi graph

The Wi-Fi section includes a live download/upload bar graph that updates every second and retains ~40 seconds of history:

- **Green bars** (upward) — download rate
- **Purple bars** (downward) — upload rate
- Each half scales independently to its own peak, so upload activity is always visible even when download is much faster
- Current rates are shown above the graph in the Download/Upload rows
- Graph hides when the Wi-Fi section is collapsed

## Disk graph

The Disk section includes a live read/write bar graph that updates every second and retains ~40 seconds of history:

- **Orange bars** (upward) — read rate
- **Teal bars** (downward) — write rate
- Each half scales independently to its own peak
- Current read/write rates are shown above the graph
- Lifetime bytes read/written shown below
- Graph remains visible even when the Disk section is collapsed

## Signal scale

Wi-Fi percentage maps RSSI to the practical range −90 dBm (0%) → −30 dBm (100%):

| dBm | % | Quality |
|-----|---|---------|
| −30 | 100% | Outstanding |
| −50 | 67%  | Excellent |
| −60 | 50%  | Good |
| −67 | 38%  | Usable minimum |
| −75 | 25%  | Weak |
| −90 | 0%   | Unusable |

CPU/GPU/memory temp percentage maps 30°C (idle, 0%) → 100°C (throttle, 100%). Battery temp uses a separate scale: 20°C (0%) → 50°C (100%). Disk temp uses 20°C (0%) → 60°C (100%).

Temperature unit (°C/°F) is toggled via the "Use Fahrenheit" checkbox and persists across restarts.

## How it works

CPU/GPU temperature, memory, fan, and disk-temp data is read from the System Management Controller (SMC) via IOKit. GPU utilization (Device, Renderer, Tiler %) comes from the `AGXAccelerator` IOKit registry entry. Battery charge and cycle count come from the `AppleSmartBattery` IOKit registry entry. Disk model, S.M.A.R.T. status, and lifetime bytes come from `IOBlockStorageDriver` and its parent NVMe controller. Wi-Fi signal and interface stats come from CoreWLAN and `getifaddrs`. No `sudo`, no third-party tools.

Two timers run independently: graphs (Wi-Fi bandwidth, disk I/O) refresh every 1 second; all other stats refresh every 3 seconds.

## Requirements

- macOS (tested on macOS 15 Sequoia and macOS 26 Tahoe)
- Intel or Apple Silicon Mac (M1–M5 tested)
- Xcode Command Line Tools: `xcode-select --install`

## Build & run

```bash
git clone https://github.com/eparker71/vitals.git
cd vitals

# Build only
bash build.sh

# Run (stays in menu bar, no Dock icon)
./Vitals &
```

## Auto-start at login

```bash
# Build + install LaunchAgent in one step
bash build.sh --install
```

This generates `~/Library/LaunchAgents/com.eric.vitals.plist` with the correct
path for your machine and loads it immediately. The app will restart automatically
at every login.

To stop and uninstall:

```bash
launchctl unload ~/Library/LaunchAgents/com.eric.vitals.plist
rm ~/Library/LaunchAgents/com.eric.vitals.plist
```

## Files

| File | Purpose |
|------|---------|
| `Vitals.swift` | App source |
| `build.sh` | Compile script (`--install` flag sets up login auto-start) |
| `com.eric.vitals.plist` | LaunchAgent template (path substituted at install time) |
