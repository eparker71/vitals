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

    // Populated at init: one entry per detected per-core key (TC1C, TC2C, …)
    private(set) var coreKeys: [(label: String, key: String)] = []

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        detectCoreKeys()
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // Probe TC1C..TC8C at startup so we know which cores exist on this machine.
    private func detectCoreKeys() {
        for i in 1...8 {
            let key = "TC\(i)C"
            if keyIsReadable(key) { coreKeys.append((label: "Core \(i)", key: key)) }
        }
        // Fallback if no per-core keys found: try package-level sensors
        if coreKeys.isEmpty {
            for key in ["TC0P", "TCXC", "TC0E"] {
                if keyIsReadable(key) { coreKeys.append((label: "CPU", key: key)); break }
            }
        }
    }

    private func keyIsReadable(_ key: String) -> Bool {
        guard let info = getKeyInfo(key) else { return false }
        return info.result == 0 && info.keyInfo.dataSize > 0
            && dataTypeString(info.keyInfo.dataType) == "sp78"
    }

    // Returns (label, °C) for each detected core, sorted hottest first.
    func coreTemperatures() -> [(label: String, temp: Double)] {
        coreKeys.compactMap { entry in
            guard let t = readSP78(key: entry.key), t > 1, t < 125 else { return nil }
            return (entry.label, t)
        }.sorted { $0.temp > $1.temp }
    }

    private func readSP78(key: String) -> Double? {
        guard let info = getKeyInfo(key),
              info.keyInfo.dataSize > 0,
              dataTypeString(info.keyInfo.dataType) == "sp78" else { return nil }
        var input = SMCParam(), output = SMCParam()
        input.key = fourCC(key)
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5  // kSMCReadKey
        guard callSMC(&input, &output) == kIOReturnSuccess else { return nil }
        return Double(output.bytes.0) + Double(output.bytes.1) / 256.0
    }

    private func getKeyInfo(_ key: String) -> SMCParam? {
        var input = SMCParam(), output = SMCParam()
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
        return b.map { ($0 >= 32 && $0 < 127) ? String(UnicodeScalar($0)) : "?" }.joined()
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
        // One row per detected core; minimum 1 for the "unavailable" case
        let cpuRowCount = max(1, smc?.coreKeys.count ?? 1)
        addSection(title: "CPU", rows: cpuRowCount, into: &cpuItems)
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

        let rows: [(String, String)] = [
            ("SSID",     ssid),
            ("Signal",   "\(rssi) dBm  →  \(pct)%"),
            ("Noise",    "\(noise) dBm"),
            ("SNR",      "\(snr) dB  \(snrLabel(snr))"),
            ("Channel",  "\(ch)  \(band)"),
            ("TX Rate",  "\(Int(tx)) Mbps"),
            ("Security", sec),
        ]
        for (i, (label, value)) in rows.enumerated() {
            wifiItems[i].title = "  \(label): \(value)"
        }
        updateTitle(rssi: rssi, pct: pct, maxCoreTemp: nil)
    }

    // MARK: CPU

    func refreshCPU() {
        let cores = smc?.coreTemperatures() ?? []
        // cores is already sorted hottest-first
        if cores.isEmpty {
            cpuItems[0].title = "  Temp: unavailable"
            cpuItems[0].attributedTitle = nil
        } else {
            for (i, core) in cores.enumerated() {
                let t   = Int(core.temp.rounded())
                let pct = cpuTempPercent(t)
                cpuItems[i].attributedTitle = cpuTempLine(label: core.label, temp: t, pct: pct)
            }
        }
        let maxTemp = cores.first.map { Int($0.temp.rounded()) }
        updateTitle(rssi: nil, pct: nil, maxCoreTemp: maxTemp)
    }

    // MARK: Title bar

    private var lastRssi: Int = 0
    private var lastPct:  Int = 0
    private var lastMaxTemp: Int? = nil

    func updateTitle(rssi: Int?, pct: Int?, maxCoreTemp: Int?) {
        if let r = rssi { lastRssi = r }
        if let p = pct  { lastPct  = p }
        if let t = maxCoreTemp { lastMaxTemp = t }

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "\(lastRssi) dBm (\(lastPct)%) "))
        out.append(colorMeter(pct: lastPct, inverted: false))
        if let t = lastMaxTemp {
            out.append(NSAttributedString(string: " │ \(t)°C "))
            out.append(colorMeter(pct: cpuTempPercent(t), inverted: true))
        }
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

    // 30°C (idle) = 0%, 100°C (throttle point) = 100%
    func cpuTempPercent(_ temp: Int) -> Int {
        let c = max(30, min(100, temp))
        return (c - 30) * 100 / 70
    }

    func cpuTempLine(label: String, temp: Int, pct: Int) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "  \(label): \(temp)°C (\(pct)%) ")
        out.append(colorMeter(pct: pct, inverted: true))
        return out
    }

    // MARK: Color meter

    /// 10-square color meter.
    /// inverted=false → WiFi style (green = high)
    /// inverted=true  → CPU style  (green = low, red = high)
    func colorMeter(pct: Int, inverted: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let filled = max(0, min(10, (pct + 9) / 10))
        for i in 0..<10 {
            let isFilled = i < filled
            let segPct = i * 10 + 5
            let color: NSColor
            if !isFilled {
                color = .tertiaryLabelColor
            } else if inverted {
                color = segPct < 30 ? .systemGreen : segPct < 70 ? .systemYellow : .systemRed
            } else {
                color = segPct >= 60 ? .systemGreen : segPct >= 30 ? .systemYellow : .systemRed
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
        case .none:                           return "Open"
        case .WEP:                            return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal:                   return "WPA2"
        case .wpa3Personal:                   return "WPA3"
        default:                              return "Other"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
