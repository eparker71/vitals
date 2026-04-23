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
    private(set) var coreKeys: [(label: String, key: String)] = []

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        detectCoreKeys()
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // MARK: CPU cores

    private func detectCoreKeys() {
        for i in 1...8 {
            let key = "TC\(i)C"
            if keyIsReadableSP78(key) { coreKeys.append((label: "Core \(i)", key: key)) }
        }
        if coreKeys.isEmpty {
            for key in ["TC0P", "TCXC", "TC0E"] {
                if keyIsReadableSP78(key) { coreKeys.append((label: "CPU", key: key)); break }
            }
        }
    }

    func coreTemperatures() -> [(label: String, temp: Double)] {
        coreKeys.compactMap { entry in
            guard let t = readSP78(key: entry.key), t > 1, t < 125 else { return nil }
            return (entry.label, t)
        }.sorted { $0.temp > $1.temp }
    }

    // MARK: GPU

    func gpuTemperature() -> Double? {
        for key in ["TG1D", "TCGC"] {
            if let t = readSP78(key: key), t > 1, t < 125 { return t }
        }
        return nil
    }

    // MARK: Memory

    func memoryTemperature() -> Double? {
        readSP78(key: "TM0P")
    }

    // MARK: Fan — fpe2: value = raw_uint16 / 4.0

    func fanSpeedRPM() -> Double? { readFPE2(key: "F0Ac") }
    func fanSpeedMaxRPM() -> Double? { readFPE2(key: "F0Mx") }

    // MARK: Battery

    func batteryTemperature() -> Double? {
        ["TB0T", "TB1T", "TB2T"]
            .compactMap { readSP78(key: $0) }
            .filter { $0 > 1 && $0 < 80 }
            .max()
    }

    func batteryCycles() -> Int? {
        readUI16(key: "B0CT").map { Int($0) }
    }

    // Returns 0–100
    func batteryCapacityPct() -> Int? {
        guard let remaining = readUI16(key: "B0RM"),
              let full      = readUI16(key: "B0FC"),
              full > 0 else { return nil }
        return min(100, Int(Double(remaining) / Double(full) * 100))
    }

    // MARK: Power — P* keys use sp78 encoding but represent watts

    func cpuPowerWatts() -> Double? { readSP78(key: "PCPC") }
    func systemPowerWatts() -> Double? { readSP78(key: "PDTR") }

    // MARK: Private read helpers

    private func keyIsReadableSP78(_ key: String) -> Bool {
        guard let info = getKeyInfo(key) else { return false }
        return info.result == 0 && info.keyInfo.dataSize > 0
            && dataTypeString(info.keyInfo.dataType) == "sp78"
    }

    private func readSP78(key: String) -> Double? {
        guard let info = getKeyInfo(key),
              info.result == 0,
              info.keyInfo.dataSize > 0,
              dataTypeString(info.keyInfo.dataType) == "sp78" else { return nil }
        var i = SMCParam(), o = SMCParam()
        i.key = fourCC(key); i.keyInfo.dataSize = info.keyInfo.dataSize; i.data8 = 5
        guard callSMC(&i, &o) == kIOReturnSuccess else { return nil }
        return Double(o.bytes.0) + Double(o.bytes.1) / 256.0
    }

    private func readFPE2(key: String) -> Double? {
        guard let info = getKeyInfo(key),
              info.result == 0,
              info.keyInfo.dataSize > 0,
              dataTypeString(info.keyInfo.dataType) == "fpe2" else { return nil }
        var i = SMCParam(), o = SMCParam()
        i.key = fourCC(key); i.keyInfo.dataSize = info.keyInfo.dataSize; i.data8 = 5
        guard callSMC(&i, &o) == kIOReturnSuccess else { return nil }
        let raw = UInt16(o.bytes.0) << 8 | UInt16(o.bytes.1)
        return Double(raw) / 4.0
    }

    private func readUI16(key: String) -> UInt16? {
        guard let info = getKeyInfo(key),
              info.result == 0,
              info.keyInfo.dataSize > 0 else { return nil }
        var i = SMCParam(), o = SMCParam()
        i.key = fourCC(key); i.keyInfo.dataSize = info.keyInfo.dataSize; i.data8 = 5
        guard callSMC(&i, &o) == kIOReturnSuccess else { return nil }
        return UInt16(o.bytes.0) << 8 | UInt16(o.bytes.1)
    }

    private func getKeyInfo(_ key: String) -> SMCParam? {
        var i = SMCParam(), o = SMCParam()
        i.key = fourCC(key); i.data8 = 9
        guard callSMC(&i, &o) == kIOReturnSuccess else { return nil }
        return o
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
    var gpuItems:  [NSMenuItem] = []
    var memItems:  [NSMenuItem] = []
    var fanItems:  [NSMenuItem] = []
    var batItems:  [NSMenuItem] = []
    var pwrItems:  [NSMenuItem] = []

    let smc = SMCReader()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in self.refresh() }
    }

    func buildMenu() {
        addSection("Wi-Fi",   rows: 7,                              into: &wifiItems)
        sep()
        addSection("CPU",     rows: max(1, smc?.coreKeys.count ?? 1), into: &cpuItems)
        sep()
        addSection("GPU",     rows: 1, into: &gpuItems)
        sep()
        addSection("Memory",  rows: 1, into: &memItems)
        sep()
        addSection("Fan",     rows: 1, into: &fanItems)
        sep()
        addSection("Battery", rows: 3, into: &batItems)
        sep()
        addSection("Power",   rows: 2, into: &pwrItems)
        sep()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func sep() { menu.addItem(.separator()) }

    private func addSection(_ title: String, rows: Int, into items: inout [NSMenuItem]) {
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

    // MARK: Refresh

    func refresh() {
        refreshWifi()
        refreshCPU()
        refreshGPU()
        refreshMemory()
        refreshFan()
        refreshBattery()
        refreshPower()
    }

    // MARK: Wi-Fi

    func refreshWifi() {
        guard let iface = CWWiFiClient.shared().interface() else {
            statusItem.button?.title = "No WiFi"; return
        }
        let rssi  = iface.rssiValue()
        let noise = iface.noiseMeasurement()
        let pct   = rssiPercent(rssi)

        let rows: [(String, String)] = [
            ("SSID",     iface.ssid() ?? "—"),
            ("Signal",   "\(rssi) dBm  →  \(pct)%"),
            ("Noise",    "\(noise) dBm"),
            ("SNR",      "\(rssi - noise) dB  \(snrLabel(rssi - noise))"),
            ("Channel",  "\(iface.wlanChannel()?.channelNumber ?? 0)  \(iface.wlanChannel().map { bandLabel($0) } ?? "—")"),
            ("TX Rate",  "\(Int(iface.transmitRate())) Mbps"),
            ("Security", iface.security().label),
        ]
        for (i, (label, value)) in rows.enumerated() {
            wifiItems[i].title = "  \(label): \(value)"
        }
        updateTitle(rssi: rssi, pct: pct, maxCoreTemp: nil)
    }

    // MARK: CPU

    func refreshCPU() {
        let cores = smc?.coreTemperatures() ?? []
        if cores.isEmpty {
            cpuItems[0].title = "  Temp: unavailable"
            cpuItems[0].attributedTitle = nil
        } else {
            for (i, core) in cores.enumerated() {
                let t = Int(core.temp.rounded())
                cpuItems[i].attributedTitle = tempLine(label: core.label, temp: t, pct: cpuTempPercent(t))
            }
        }
        updateTitle(rssi: nil, pct: nil, maxCoreTemp: cores.first.map { Int($0.temp.rounded()) })
    }

    // MARK: GPU

    func refreshGPU() {
        if let t = smc?.gpuTemperature() {
            let temp = Int(t.rounded())
            gpuItems[0].attributedTitle = tempLine(label: "Temp", temp: temp, pct: cpuTempPercent(temp))
        } else {
            gpuItems[0].title = "  Temp: unavailable"
            gpuItems[0].attributedTitle = nil
        }
    }

    // MARK: Memory

    func refreshMemory() {
        if let t = smc?.memoryTemperature() {
            let temp = Int(t.rounded())
            memItems[0].attributedTitle = tempLine(label: "Temp", temp: temp, pct: cpuTempPercent(temp))
        } else {
            memItems[0].title = "  Temp: unavailable"
            memItems[0].attributedTitle = nil
        }
    }

    // MARK: Fan

    func refreshFan() {
        if let rpm = smc?.fanSpeedRPM(), let maxRpm = smc?.fanSpeedMaxRPM(), maxRpm > 0 {
            let pct = min(100, Int(rpm / maxRpm * 100))
            let out = NSMutableAttributedString(string: "  Speed: \(Int(rpm)) RPM (\(pct)%) ")
            out.append(colorMeter(pct: pct, inverted: false))
            fanItems[0].attributedTitle = out
        } else {
            fanItems[0].title = "  Speed: unavailable"
            fanItems[0].attributedTitle = nil
        }
    }

    // MARK: Battery

    func refreshBattery() {
        // Row 0: temperature
        if let t = smc?.batteryTemperature() {
            let temp = Int(t.rounded())
            let pct  = cpuTempPercent(temp)
            batItems[0].attributedTitle = tempLine(label: "Temp", temp: temp, pct: pct)
        } else {
            batItems[0].title = "  Temp: unavailable"
            batItems[0].attributedTitle = nil
        }
        // Row 1: cycle count
        if let cycles = smc?.batteryCycles() {
            batItems[1].title = "  Cycle count: \(cycles)"
        } else {
            batItems[1].title = "  Cycle count: unavailable"
        }
        // Row 2: capacity
        if let pct = smc?.batteryCapacityPct() {
            let out = NSMutableAttributedString(string: "  Capacity: \(pct)% ")
            // Green = high capacity, red = degraded (inverted=false like WiFi)
            out.append(colorMeter(pct: pct, inverted: false))
            batItems[2].attributedTitle = out
        } else {
            batItems[2].title = "  Capacity: unavailable"
            batItems[2].attributedTitle = nil
        }
    }

    // MARK: Power

    func refreshPower() {
        if let w = smc?.cpuPowerWatts() {
            pwrItems[0].title = String(format: "  CPU package: %.1f W", w)
        } else {
            pwrItems[0].title = "  CPU package: unavailable"
        }
        if let w = smc?.systemPowerWatts() {
            pwrItems[1].title = String(format: "  System total: %.1f W", w)
        } else {
            pwrItems[1].title = "  System total: unavailable"
        }
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
        out.append(colorMeter(pct: lastPct, inverted: false, small: true))
        if let t = lastMaxTemp {
            out.append(NSAttributedString(string: " │ \(t)°C"))
        }
        statusItem.button?.attributedTitle = out
    }

    // MARK: Shared helpers

    // 30°C (idle) = 0%, 100°C (throttle) = 100%
    func cpuTempPercent(_ temp: Int) -> Int {
        let c = max(30, min(100, temp))
        return (c - 30) * 100 / 70
    }

    func tempLine(label: String, temp: Int, pct: Int) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "  \(label): \(temp)°C (\(pct)%) ")
        out.append(colorMeter(pct: pct, inverted: true))
        return out
    }

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

    // MARK: Color meter

    func colorMeter(pct: Int, inverted: Bool, small: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let filled = max(0, min(10, (pct + 9) / 10))
        let font = small ? NSFont.monospacedSystemFont(ofSize: 7, weight: .regular) : nil
        for i in 0..<10 {
            let isFilled = i < filled
            let segPct   = i * 10 + 5
            let color: NSColor
            if !isFilled {
                color = .tertiaryLabelColor
            } else if inverted {
                color = segPct < 30 ? .systemGreen : segPct < 70 ? .systemYellow : .systemRed
            } else {
                color = segPct >= 60 ? .systemGreen : segPct >= 30 ? .systemYellow : .systemRed
            }
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let f = font { attrs[.font] = f }
            out.append(NSAttributedString(string: isFilled ? "■" : "□", attributes: attrs))
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
