# WifiSignal

A lightweight macOS menu bar dashboard showing real system stats — Wi-Fi signal strength, CPU core temps, GPU temp, memory temp, fan speed, battery health, and power draw — all from a single menu bar item with no Dock icon.

## Menu bar

Updates every 3 seconds:

```
-56 dBm (57%) ■■■■■■□□□□ │ 52°C
```

- **Wi-Fi**: RSSI in dBm, percentage, color meter
- **CPU**: hottest core temperature
- Meter squares are color-coded: red → yellow → green (WiFi) / green → yellow → red (heat)

## Panel (click to expand)

```
  Wi-Fi
  SSID:      MyNetwork
  Signal:    -56 dBm  →  57%
  Noise:     -88 dBm
  SNR:       32 dB  (excellent)
  Channel:   153  5 GHz
  TX Rate:   243 Mbps
  Security:  WPA2
  ───────────────────────────
  CPU
  Core 1:    58°C (40%) ■■■■□□□□□□
  Core 2:    54°C (34%) ■■■■□□□□□□
  ───────────────────────────
  GPU
  Temp:      52°C (31%) ■■■■□□□□□□
  ───────────────────────────
  Memory
  Temp:      43°C (19%) ■■□□□□□□□□
  ───────────────────────────
  Fan
  Speed:     2200 RPM (35%) ■■■■□□□□□□
  ───────────────────────────
  Battery
  Temp:      29°C (0%)  □□□□□□□□□□
  Cycle count: 88
  Capacity:  100% ■■■■■■■■■■
  ───────────────────────────
  Power
  CPU package:   16.1 W
  System total:  35.9 W
  ───────────────────────────
  Quit
```

CPU cores are sorted hottest-first and detected dynamically, so it works on any Intel Mac regardless of core count.

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

CPU/GPU/memory temp percentage maps 30°C (idle, 0%) → 100°C (throttle point, 100%).

## How it works

All sensor data is read directly from the System Management Controller (SMC) via IOKit — no `sudo`, no third-party tools. Wi-Fi data comes from CoreWLAN.

## Requirements

- macOS (tested on macOS 15 Sequoia)
- Intel Mac (SMC key names differ on Apple Silicon — PRs welcome)
- Xcode Command Line Tools: `xcode-select --install`

## Build & run

```bash
git clone https://github.com/eparker71/wifisignal.git
cd wifisignal

# Build only
bash build.sh

# Run (stays in menu bar, no Dock icon)
./WifiSignal &
```

## Auto-start at login

```bash
# Build + install LaunchAgent in one step
bash build.sh --install
```

This generates `~/Library/LaunchAgents/com.eric.wifisignal.plist` with the correct
path for your machine and loads it immediately. The app will restart automatically
at every login.

To stop and uninstall:

```bash
launchctl unload ~/Library/LaunchAgents/com.eric.wifisignal.plist
rm ~/Library/LaunchAgents/com.eric.wifisignal.plist
```

## Files

| File | Purpose |
|------|---------|
| `WifiSignal.swift` | App source |
| `build.sh` | Compile script (`--install` flag sets up login auto-start) |
| `com.eric.wifisignal.plist` | LaunchAgent template (path substituted at install time) |
