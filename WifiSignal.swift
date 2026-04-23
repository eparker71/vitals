import Cocoa
import CoreWLAN

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    let menu = NSMenu()
    var detailItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in self.refresh() }
    }

    func setupMenu() {
        // Placeholder items updated each tick
        for _ in 0..<8 { detailItems.append(NSMenuItem()) }
        detailItems.forEach { menu.addItem($0) }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func refresh() {
        guard let iface = CWWiFiClient.shared().interface() else {
            statusItem.button?.title = "WiFi?"
            return
        }

        let rssi  = iface.rssiValue()
        let noise = iface.noiseMeasurement()
        let snr   = rssi - noise
        let ssid  = iface.ssid() ?? "—"
        let ch    = iface.wlanChannel()?.channelNumber ?? 0
        let band  = iface.wlanChannel().map { bandLabel($0) } ?? "—"
        let tx    = iface.transmitRate()
        let sec   = iface.security().label

        let pct = rssiPercent(rssi)
        statusItem.button?.attributedTitle = coloredTitle(rssi: rssi, pct: pct)

        let rows: [(String, String)] = [
            ("SSID",    ssid),
            ("Signal",  "\(rssi) dBm  →  \(pct)%"),
            ("Noise",   "\(noise) dBm"),
            ("SNR",     "\(snr) dB  \(snrLabel(snr))"),
            ("Channel", "\(ch)  \(band)"),
            ("TX Rate", "\(Int(tx)) Mbps"),
            ("Security",sec),
        ]

        for (i, (label, value)) in rows.enumerated() {
            detailItems[i].title = "\(label): \(value)"
        }
        // hide spare slot
        detailItems[rows.count].isHidden = true
    }

    // MARK: helpers

    // Builds the menu-bar label: plain text + a 10-block color meter
    func coloredTitle(rssi: Int, pct: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // Plain text portion inherits the system menu-bar font/color
        out.append(NSAttributedString(string: "\(rssi) dBm (\(pct)%) "))

        // 10 segmented blocks; each block covers 10 percentage points.
        // Color per segment: 0-29 % → red, 30-59 % → yellow, 60-100 % → green
        let total = 10
        let filled = (pct + 9) / 10   // round up so ≥1% shows at least one block
        for i in 0..<total {
            let isFilled = i < filled
            let segmentMidPct = i * 10 + 5
            let color: NSColor
            if !isFilled {
                color = NSColor.tertiaryLabelColor
            } else if segmentMidPct < 30 {
                color = .systemRed
            } else if segmentMidPct < 60 {
                color = .systemYellow
            } else {
                color = .systemGreen
            }
            let block = NSAttributedString(string: isFilled ? "■" : "□",
                                           attributes: [.foregroundColor: color])
            out.append(block)
        }
        return out
    }

    // Maps RSSI to 0–100 using the practical range -90 dBm (0%) → -30 dBm (100%)
    func rssiPercent(_ rssi: Int) -> Int {
        let clamped = max(-90, min(-30, rssi))
        return (clamped + 90) * 100 / 60
    }

    func snrLabel(_ snr: Int) -> String {
        switch snr {
        case ..<10:  return "(poor)"
        case ..<20:  return "(fair)"
        case ..<30:  return "(good)"
        default:     return "(excellent)"
        }
    }

    func bandLabel(_ ch: CWChannel) -> String {
        switch ch.channelBand {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default:        return ""
        }
    }
}

extension CWSecurity {
    var label: String {
        switch self {
        case .none:          return "Open"
        case .WEP:           return "WEP"
        case .wpaPersonal,
             .wpaPersonalMixed:  return "WPA"
        case .wpa2Personal:      return "WPA2"
        case .wpa3Personal:  return "WPA3"
        default:             return "Other"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
