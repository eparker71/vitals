import Cocoa
import CoreWLAN
import IOKit

// MARK: - SMC reader (IOKit, no sudo required)

private struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0
    var reserved: UInt8 = 0, release: UInt16 = 0
}
private struct SMCPLimit {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}
private struct SMCKeyInfo {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
    var _pad: (UInt8, UInt8, UInt8) = (0, 0, 0)  // match C struct trailing padding → 12 bytes total
}
private struct SMCParam {
    var key: UInt32 = 0
    var vers      = SMCVersion()
    var pLimit    = SMCPLimit()
    var keyInfo   = SMCKeyInfo()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0, data32: UInt32 = 0
    var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

class SMCReader {
    private var conn: io_connect_t = 0

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // Reads CPU temperature. Key priority for Intel Macs:
    //   TC0P = CPU proximity (smooth, package-level)
    //   TCXC = CPU PECI junction temp
    //   TC1C/TC2C = individual core temps (spiky under load)
    func cpuTemperature() -> Double? {
        let candidates = ["TC0P", "TCXC", "TC1C", "TC0E", "TC0F"]
        for key in candidates {
            if let t = readSP78(key: key), t > 1, t < 125 { return t }
        }
        return nil
    }

    private func readSP78(key: String) -> Double? {
        guard var info = getKeyInfo(key) else { return nil }
        guard info.keyInfo.dataSize > 0 else { return nil }
        guard dataTypeString(info.keyInfo.dataType) == "sp78" else { return nil }

        var input = SMCParam()
        var output = SMCParam()
        input.key = fourCC(key)
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5  // kSMCReadKey
        guard callSMC(&input, &output) == kIOReturnSuccess else { return nil }

        // sp78: signed fixed-point 7.8 — high byte is integer, low byte is fraction
        return Double(output.bytes.0) + Double(output.bytes.1) / 256.0
    }

    private func getKeyInfo(_ key: String) -> SMCParam? {
        var input = SMCParam()
        var output = SMCParam()
        input.key = fourCC(key)
        input.data8 = 9  // kSMCGetKeyInfo
        guard callSMC(&input, &output) == kIOReturnSuccess else { return nil }
        return output
    }

    private func callSMC(_ input: inout SMCParam, _ output: inout SMCParam) -> IOReturn {
        var inSize  = MemoryLayout<SMCParam>.stride
        var outSize = MemoryLayout<SMCParam>.stride
        return IOConnectCallStructMethod(conn, 2, &input, inSize, &output, &outSize)
    }

    private func fourCC(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        guard b.count == 4 else { return 0 }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func dataTypeString(_ type: UInt32) -> String {
        let b: [UInt8] = [UInt8((type>>24)&0xff), UInt8((type>>16)&0xff),
                          UInt8((type>>8)&0xff),  UInt8(type&0xff)]
        return String(bytes: b, encoding: .ascii) ?? ""
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    let menu = NSMenu()
    var wifiItems: [NSMenuItem] = []
    var cpuItems:  [NSMenuItem] = []
    let smc = SMCReader()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in self.refresh() }
    }

    func buildMenu() {
        addSection(title: "Wi-Fi", rows: 7, into: &wifiItems)
        menu.addItem(.separator())
        addSection(title: "CPU", rows: 2, into: &cpuItems)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addSection(title: String, rows: Int, into items: inout [NSMenuItem]) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = sectionHeader(title)
        menu.addItem(header)
        for _ in 0..<rows {
            let item = NSMenuItem()
            items.append(item)
            menu.addItem(item)
        }
    }

    private func sectionHeader(_ title: String) -> NSAttributedString {
        NSAttributedString(string: "  \(title)", attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    func refresh() {
        refreshWifi()
        refreshCPU()
    }

    // MARK: Wi-Fi

    func refreshWifi() {
        guard let iface = CWWiFiClient.shared().interface() else {
            statusItem.button?.title = "No WiFi"
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
        let pct   = rssiPercent(rssi)

        let wifiRows: [(String, String)] = [
            ("SSID",     ssid),
            ("Signal",   "\(rssi) dBm  →  \(pct)%"),
            ("Noise",    "\(noise) dBm"),
            ("SNR",      "\(snr) dB  \(snrLabel(snr))"),
            ("Channel",  "\(ch)  \(band)"),
            ("TX Rate",  "\(Int(tx)) Mbps"),
            ("Security", sec),
        ]
        for (i, (label, value)) in wifiRows.enumerated() {
            wifiItems[i].title = "  \(label): \(value)"
        }

        updateTitle(rssi: rssi, pct: pct)
    }

    // MARK: CPU

    func refreshCPU() {
        if let temp = smc?.cpuTemperature() {
            let t = Int(temp.rounded())
            let pct = cpuTempPercent(t)
            cpuItems[0].title = "  Temp: \(t) °C  →  \(pct)%"
            cpuItems[0].attributedTitle = cpuTempLine(t, pct: pct)
            cpuItems[1].isHidden = true
        } else {
            cpuItems[0].title = "  Temp: unavailable"
            cpuItems[1].isHidden = true
        }
        updateTitle(rssi: nil, pct: nil)  // re-trigger to pick up CPU value
    }

    // MARK: Title bar

    private var lastRssi: Int = 0
    private var lastPct:  Int = 0

    func updateTitle(rssi: Int?, pct: Int?) {
        if let r = rssi { lastRssi = r }
        if let p = pct  { lastPct  = p }

        let cpuStr: String
        if let temp = smc?.cpuTemperature() {
            cpuStr = " │ \(Int(temp.rounded()))°C"
        } else {
            cpuStr = ""
        }

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "\(lastRssi) dBm (\(lastPct)%) "))
        out.append(colorMeter(pct: lastPct, maxDeg: 60, goodAbove: 60, warnAbove: 30))
        out.append(NSAttributedString(string: cpuStr))
        statusItem.button?.attributedTitle = out
    }

    // MARK: Helpers — WiFi

    func rssiPercent(_ rssi: Int) -> Int {
        let c = max(-90, min(-30, rssi))
        return (c + 90) * 100 / 60
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

    // MARK: Helpers — CPU temp

    // 0% = 30°C (idle), 100% = 100°C (throttle threshold)
    func cpuTempPercent(_ temp: Int) -> Int {
        let c = max(30, min(100, temp))
        return (c - 30) * 100 / 70
    }

    func cpuTempLine(_ temp: Int, pct: Int) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "  Temp: \(temp) °C  →  \(pct)% ")
        // For CPU temp: green = cool, yellow = warm, red = hot (inverse of WiFi)
        out.append(colorMeter(pct: pct, maxDeg: 10, goodAbove: -1, warnAbove: 30))
        return out
    }

    // MARK: Color meter

    /// Renders a 10-square color meter.
    /// goodAbove / warnAbove control color thresholds (set goodAbove = -1 to invert for heat).
    func colorMeter(pct: Int, maxDeg: Int, goodAbove: Int, warnAbove: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let total = 10
        let filled = max(0, min(total, (pct + 9) / 10))
        for i in 0..<total {
            let isFilled = i < filled
            let segPct = i * 10 + 5
            let color: NSColor
            if !isFilled {
                color = .tertiaryLabelColor
            } else if goodAbove >= 0 {
                // WiFi style: green = high, yellow = mid, red = low
                color = segPct >= goodAbove ? .systemGreen : segPct >= warnAbove ? .systemYellow : .systemRed
            } else {
                // CPU style: green = low, yellow = mid, red = high
                color = segPct < 30 ? .systemGreen : segPct < 70 ? .systemYellow : .systemRed
            }
            out.append(NSAttributedString(string: isFilled ? "■" : "□",
                                          attributes: [.foregroundColor: color]))
        }
        return out
    }
}

extension CWSecurity {
    var label: String {
        switch self {
        case .none:                          return "Open"
        case .WEP:                           return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal:                  return "WPA2"
        case .wpa3Personal:                  return "WPA3"
        default:                             return "Other"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
