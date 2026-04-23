# WifiSignal

A lightweight macOS menu bar app that shows real Wi-Fi signal values instead of the vague signal-bar icon.

![menu bar example](https://via.placeholder.com/400x30/1a1a1a/ffffff?text=-56+dBm+(57%25)+%E2%96%A0%E2%96%A0%E2%96%A0%E2%96%A0%E2%96%A0%E2%96%A0%E2%96%A1%E2%96%A1%E2%96%A1%E2%96%A1)

## What it shows

**Menu bar title** — updates every 3 seconds:
```
-56 dBm (57%) ■■■■■■□□□□
```

**Click to expand** for full detail:
```
SSID:     MyNetwork
Signal:   -56 dBm  →  57%
Noise:    -88 dBm
SNR:      32 dB  (excellent)
Channel:  153  5 GHz
TX Rate:  243 Mbps
Security: WPA2
```

## Signal scale

The percentage maps RSSI to the practical range −90 dBm (0 %) → −30 dBm (100 %):

| dBm | % | Quality |
|-----|---|---------|
| −30 | 100% | Outstanding |
| −50 | 67%  | Excellent |
| −60 | 50%  | Good |
| −67 | 38%  | Usable minimum |
| −75 | 25%  | Weak |
| −90 | 0%   | Unusable |

The color meter segments are:
- **Red** — 0–29 %
- **Yellow** — 30–59 %
- **Green** — 60–100 %

## Requirements

- macOS (tested on macOS 15 Sequoia)
- Xcode Command Line Tools (`xcode-select --install`)

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

This generates a `~/Library/LaunchAgents/com.eric.wifisignal.plist` with the
correct path for your machine and loads it immediately.

To stop and uninstall:
```bash
launchctl unload ~/Library/LaunchAgents/com.eric.wifisignal.plist
rm ~/Library/LaunchAgents/com.eric.wifisignal.plist
```

## Files

| File | Purpose |
|------|---------|
| `WifiSignal.swift` | App source |
| `build.sh` | Compile script |
| `com.eric.wifisignal.plist` | LaunchAgent for login auto-start |
