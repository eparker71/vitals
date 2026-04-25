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
        // Apple Silicon: Tp-style thermal cluster sensors (flt, little-endian)
        let digits = "0123456789ABCDEF"
        for hi in digits.map(String.init) {
            for lo in digits.map(String.init) {
                let key = "Tp\(hi)\(lo)"
                if readTemp(key) != nil { coreKeys.append((label: "Cluster \(coreKeys.count + 1)", key: key)) }
            }
        }
        if !coreKeys.isEmpty { return }
        // Intel/older: TC-style per-core sensors (sp78), up to 16 cores
        for i in 1...16 {
            let key = "TC\(i)C"
            if readTemp(key) != nil { coreKeys.append((label: "Core \(i)", key: key)) }
        }
        if coreKeys.isEmpty {
            for key in ["TC0P", "TCXC", "TC0E"] {
                if readTemp(key) != nil { coreKeys.append((label: "CPU", key: key)); break }
            }
        }
    }

    func coreTemperatures() -> [(label: String, temp: Double)] {
        coreKeys.compactMap { entry in
            guard let t = readTemp(entry.key), t > 1, t < 125 else { return nil }
            return (entry.label, t)
        }.sorted { $0.temp > $1.temp }
    }

    // MARK: GPU

    func gpuTemperature() -> Double? {
        for key in ["Tg04", "Tg0C", "Tg0d", "TG1D", "TCGC"] {
            if let t = readTemp(key) { return t }
        }
        return nil
    }

    // MARK: Memory

    func memoryTemperature() -> Double? {
        for key in ["TM0P", "Tm0P", "TM0S"] {
            if let t = readTemp(key) { return t }
        }
        return nil
    }

    // MARK: Fan — fpe2: value = raw_uint16 / 4.0

    func fanSpeedRPM() -> Double? { readFPE2(key: "F0Ac") }
    func fanSpeedMaxRPM() -> Double? { readFPE2(key: "F0Mx") }

    // MARK: Battery

    func batteryTemperature() -> Double? {
        ["TB0T", "TB1T", "TB2T"]
            .compactMap { readTemp($0) }
            .filter { $0 > 1 && $0 < 80 }
            .max()
    }

    func storageTemperature() -> Double? {
        for key in ["Ts0S", "Ts0P", "TH0A", "TH0P"] {
            if let t = readTemp(key) { return t }
        }
        return nil
    }

    // charge% and cycle count from the AppleSmartBattery registry entry
    // (more reliable than raw SMC keys whose units vary across chip generations)
    func batteryRegistryInfo() -> (chargePct: Int, cycles: Int?)? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                             IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>? = nil
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict   = props?.takeRetainedValue() as? [String: Any],
              let current = dict["CurrentCapacity"] as? Int,
              let max     = dict["MaxCapacity"]     as? Int,
              max > 0 else { return nil }
        return (min(100, current * 100 / max), dict["CycleCount"] as? Int)
    }

    // MARK: Power — Intel: sp78, Apple Silicon: flt (little-endian)

    func cpuPowerWatts() -> Double? { readSP78(key: "PCPC") ?? readFlt("PSTR") }
    func systemPowerWatts() -> Double? { readFlt("PDTR") ?? readSP78(key: "PDTR") }

    // MARK: Private read helpers

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

    // Apple Silicon SMC stores values as little-endian IEEE 754 float
    private func readFlt(_ key: String) -> Double? {
        guard let info = getKeyInfo(key),
              info.result == 0,
              info.keyInfo.dataSize == 4,
              dataTypeString(info.keyInfo.dataType) == "flt " else { return nil }
        var i = SMCParam(), o = SMCParam()
        i.key = fourCC(key); i.keyInfo.dataSize = 4; i.data8 = 5
        guard callSMC(&i, &o) == kIOReturnSuccess else { return nil }
        let raw = UInt32(o.bytes.3) << 24 | UInt32(o.bytes.2) << 16 | UInt32(o.bytes.1) << 8 | UInt32(o.bytes.0)
        return Double(Float(bitPattern: raw))
    }

    // Unified temperature reader: handles both sp78 (Intel) and flt (Apple Silicon)
    private func readTemp(_ key: String) -> Double? {
        if let t = readSP78(key: key) { return (t > 1 && t < 150) ? t : nil }
        if let t = readFlt(key) { return (t > 1 && t < 150) ? t : nil }
        return nil
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
        let inSize  = MemoryLayout<SMCParam>.stride
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

// MARK: - Disk reader

struct DiskInfo {
    var name: String = "Unknown"
    var smartStatus: String? = nil
    var bytesRead: UInt64? = nil
    var bytesWritten: UInt64? = nil
}

struct DiskReader {
    func read() -> DiskInfo? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("IOBlockStorageDriver"),
                                          &iter) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iter) }

        var svc = IOIteratorNext(iter)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(iter) }
            var info = DiskInfo()

            var dProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &dProps, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict  = dProps?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                info.bytesRead    = uint64(stats["Bytes (Read)"])
                info.bytesWritten = uint64(stats["Bytes (Write)"])
            }
            guard info.bytesRead != nil || info.bytesWritten != nil else { continue }

            // Direct child: SATA/third-party NVMe devices expose Product Name and SMART here
            var childIter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(svc, kIOServicePlane, &childIter) == kIOReturnSuccess {
                defer { IOObjectRelease(childIter) }
                var child = IOIteratorNext(childIter)
                while child != 0 {
                    defer { IOObjectRelease(child); child = IOIteratorNext(childIter) }
                    var cp: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(child, &cp, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                          let cd = cp?.takeRetainedValue() as? [String: Any] else { continue }
                    for key in ["Product Name", "Device Model", "Model"] {
                        if let n = cd[key] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty {
                            info.name = n.trimmingCharacters(in: .whitespaces); break
                        }
                    }
                    if let s = cd["SMART Status"] as? String { info.smartStatus = s }
                }
            }

            // Walk up the parent chain — Apple Silicon NVMe controller stores "Model Number" here
            if info.name == "Unknown" {
                let upOpts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                for key in ["Model Number", "Product Name", "Device Model"] {
                    guard let val = IORegistryEntrySearchCFProperty(
                            svc, kIOServicePlane, key as CFString, kCFAllocatorDefault, upOpts)
                    else { continue }
                    let s: String?
                    if let str = val as? String {
                        s = str
                    } else if let data = val as? Data {
                        s = String(bytes: data, encoding: .utf8)
                    } else {
                        s = nil
                    }
                    if let name = s?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                        info.name = name; break
                    }
                }
            }

            return info
        }
        return nil
    }

    private func uint64(_ v: Any?) -> UInt64? {
        if let n = v as? UInt64 { return n }
        if let n = v as? Int    { return UInt64(max(0, n)) }
        if let n = v as? Int64  { return n >= 0 ? UInt64(n) : nil }
        return nil
    }
}

// MARK: - Disk graph view

fileprivate class DiskGraphView: NSView {
    private struct Sample { var read: Double; var write: Double }
    private static let cap = 40
    private var samples: [Sample] = []
    var latestRead:  Double = 0
    var latestWrite: Double = 0

    init() { super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 76)) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }  // y=0 at top, increases downward

    func push(read: Double, write: Double) {
        latestRead = read; latestWrite = write
        samples.append(Sample(read: read, write: write))
        if samples.count > Self.cap { samples.removeFirst() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let W = bounds.width, H = bounds.height
        let mg: CGFloat = 33             // matches standard menu item text indentation (includes checkmark column)

        // Label strip at top (y increases downward in flipped view)
        let lbH: CGFloat = 28
        // Graph area below labels
        let gTop: CGFloat = lbH + 2
        let gBot: CGFloat = H - 4
        let gH   = gBot - gTop
        let midY = gTop + gH / 2

        // dotted center line
        let lp = NSBezierPath()
        lp.move(to: NSPoint(x: mg, y: midY))
        lp.line(to: NSPoint(x: W - mg, y: midY))
        lp.lineWidth = 0.75
        lp.setLineDash([3, 3], count: 2, phase: 0)
        NSColor(red: 0.65, green: 0.35, blue: 0.82, alpha: 0.55).setStroke()
        lp.stroke()

        let maxVal = max(65_536, samples.flatMap { [$0.read, $0.write] }.max() ?? 1)
        let halfH  = gH / 2
        let barW: CGFloat = 5, step: CGFloat = 6

        for (i, s) in samples.reversed().enumerated() {
            let x = W - mg - CGFloat(i) * step - barW
            if x < mg { break }
            let rh = CGFloat(s.read  / maxVal) * halfH
            let wh = CGFloat(s.write / maxVal) * halfH
            NSColor.systemPink.withAlphaComponent(0.88).setFill()
            NSBezierPath(rect: NSRect(x: x, y: midY - rh, width: barW, height: rh)).fill()
            NSColor.systemBlue.withAlphaComponent(0.88).setFill()
            NSBezierPath(rect: NSRect(x: x, y: midY,      width: barW, height: wh)).fill()
        }

        let half = (W - mg * 2) / 2
        drawMetric(fmt(latestRead),  sub: "Read",
                   in: NSRect(x: mg,        y: 4, width: half, height: lbH))
        drawMetric(fmt(latestWrite), sub: "Write",
                   in: NSRect(x: mg + half, y: 4, width: half, height: lbH))
    }

    private func drawMetric(_ val: String, sub: String, in r: NSRect) {
        NSAttributedString(string: val, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]).draw(at: NSPoint(x: r.minX, y: r.minY))
        NSAttributedString(string: sub, attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ]).draw(at: NSPoint(x: r.minX, y: r.minY + 15))
    }

    private func fmt(_ bps: Double) -> String {
        guard bps >= 1_024 else { return "—" }
        if bps < 1_048_576     { return String(format: "%.0f KB/s", bps / 1_024) }
        if bps < 1_073_741_824 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        return String(format: "%.1f GB/s", bps / 1_073_741_824)
    }
}

// MARK: - Collapse header view

private class CollapseHeader: NSView {
    let label: String
    var isCollapsed: Bool = false { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?

    init(label: String) {
        self.label = label
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 17))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) { onTap?() }

    override func draw(_ dirtyRect: NSRect) {
        let arrow = isCollapsed ? "▶" : "▼"
        let str = NSAttributedString(string: "  \(arrow) \(label)", attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        str.draw(at: NSPoint(x: 0, y: (bounds.height - str.size().height) / 2))
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    let menu = NSMenu()

    private var bwLastRx:   UInt64 = 0
    private var bwLastTx:   UInt64 = 0
    private var bwLastTime: Date   = .distantPast

    let wifiHeader     = NSMenuItem()
    let cpuHeader      = NSMenuItem()
    let batHeader      = NSMenuItem()
    let diskHeader     = NSMenuItem()
    let wifiSummary    = NSMenuItem()
    let cpuSummary     = NSMenuItem()
    let batSummary     = NSMenuItem()
    fileprivate let wifiHeaderView = CollapseHeader(label: "Wi-Fi")
    fileprivate let cpuHeaderView  = CollapseHeader(label: "CPU")
    fileprivate let batHeaderView  = CollapseHeader(label: "Battery")
    fileprivate let diskHeaderView = CollapseHeader(label: "Disk")

    var wifiCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "wifiCollapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "wifiCollapsed") }
    }
    var cpuCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "cpuCollapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "cpuCollapsed") }
    }
    var batCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "batCollapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "batCollapsed") }
    }
    var diskCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "diskCollapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "diskCollapsed") }
    }

    var wifiItems: [NSMenuItem] = []
    var cpuItems:  [NSMenuItem] = []
    var gpuItems:  [NSMenuItem] = []
    var memItems:  [NSMenuItem] = []
    var fanItems:  [NSMenuItem] = []
    var batItems:  [NSMenuItem] = []
    var pwrItems:  [NSMenuItem] = []
    var diskItems: [NSMenuItem] = []

    let diskReader    = DiskReader()
    fileprivate let diskGraph = DiskGraphView()
    let diskGraphItem = NSMenuItem()
    private var diskLastRx:   UInt64 = 0
    private var diskLastTx:   UInt64 = 0
    private var diskLastTime: Date   = .distantPast
    let unitItem   = NSMenuItem()

    var useFahrenheit: Bool {
        get { UserDefaults.standard.bool(forKey: "useFahrenheit") }
        set { UserDefaults.standard.set(newValue, forKey: "useFahrenheit") }
    }

    let smc = SMCReader()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in self.refresh() }
    }

    func buildMenu() {
        addCollapsible(header: wifiHeader, view: wifiHeaderView, summary: wifiSummary,
                       rows: 9, collapsed: wifiCollapsed,
                       onToggle: { [weak self] in self?.toggleWifi() }, into: &wifiItems)
        sep()
        addCollapsible(header: cpuHeader, view: cpuHeaderView, summary: cpuSummary,
                       rows: max(1, smc?.coreKeys.count ?? 1), collapsed: cpuCollapsed,
                       onToggle: { [weak self] in self?.toggleCPU() }, into: &cpuItems)
        sep()
        addSection("GPU",     rows: 1, into: &gpuItems)
        sep()
        addSection("Memory",  rows: 1, into: &memItems)
        sep()
        addSection("Fan",     rows: 1, into: &fanItems)
        sep()
        addCollapsible(header: batHeader, view: batHeaderView, summary: batSummary,
                       rows: 3, collapsed: batCollapsed,
                       onToggle: { [weak self] in self?.toggleBat() }, into: &batItems)
        sep()
        addSection("Power",   rows: 2, into: &pwrItems)
        sep()
        // Disk section — graph always visible, metadata rows toggle on collapse
        diskHeaderView.isCollapsed = diskCollapsed
        diskHeaderView.onTap = { [weak self] in self?.toggleDisk() }
        diskHeader.view = diskHeaderView
        menu.addItem(diskHeader)
        for _ in 0..<3 { let it = NSMenuItem(); diskItems.append(it); menu.addItem(it) }
        diskGraphItem.view = diskGraph
        menu.addItem(diskGraphItem)
        for _ in 0..<2 { let it = NSMenuItem(); diskItems.append(it); menu.addItem(it) }
        diskItems.forEach { $0.isHidden = diskCollapsed }
        sep()
        unitItem.title  = "Use Fahrenheit"
        unitItem.action = #selector(toggleTempUnit)
        unitItem.state  = useFahrenheit ? .on : .off
        menu.addItem(unitItem)
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

    private func addCollapsible(header: NSMenuItem, view: CollapseHeader, summary: NSMenuItem,
                                rows: Int, collapsed: Bool, onToggle: @escaping () -> Void,
                                into items: inout [NSMenuItem]) {
        view.isCollapsed = collapsed
        view.onTap = onToggle
        header.view = view
        menu.addItem(header)
        menu.addItem(summary)
        for _ in 0..<rows {
            let item = NSMenuItem(); items.append(item); menu.addItem(item)
        }
        applyCollapse(summary: summary, details: items, collapsed: collapsed)
    }

    private func applyCollapse(summary: NSMenuItem, details: [NSMenuItem], collapsed: Bool) {
        summary.isHidden = !collapsed
        details.forEach { $0.isHidden = collapsed }
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
        refreshDisk()
    }

    // MARK: Wi-Fi

    func refreshWifi() {
        guard let iface = CWWiFiClient.shared().interface() else {
            statusItem.button?.title = "No WiFi"
            wifiSummary.title = "  No WiFi"; wifiSummary.attributedTitle = nil
            return
        }
        let rssi  = iface.rssiValue()
        let noise = iface.noiseMeasurement()
        let pct   = rssiPercent(rssi)

        let rows: [(String, String)] = [
            ("SSID",     iface.ssid() ?? "—"),
            ("Noise",    "\(noise) dBm"),
            ("SNR",      "\(rssi - noise) dB  \(snrLabel(rssi - noise))"),
            ("Channel",  "\(iface.wlanChannel()?.channelNumber ?? 0)  \(iface.wlanChannel().map { bandLabel($0) } ?? "—")"),
            ("TX Rate",  "\(Int(iface.transmitRate())) Mbps"),
            ("Security", iface.security().label),
        ]
        wifiItems[0].title = "  SSID: \(iface.ssid() ?? "—")"
        let sigOut = NSMutableAttributedString(string: "  Signal: \(rssi) dBm  (\(pct)%) ")
        sigOut.append(colorMeter(pct: pct, inverted: false))
        wifiItems[1].attributedTitle = sigOut
        for (i, (label, value)) in rows.enumerated() {
            wifiItems[i + 2].title = "  \(label): \(value)"
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(bwLastTime)
        if let (rx, tx) = interfaceBytesRxTx(iface.interfaceName ?? ""),
           bwLastTime != .distantPast, elapsed > 0, rx >= bwLastRx, tx >= bwLastTx {
            let rxRate = Double(rx - bwLastRx) / elapsed
            let txRate = Double(tx - bwLastTx) / elapsed
            wifiItems[7].title = "  Download: \(formatBandwidth(rxRate))"
            wifiItems[8].title = "  Upload:   \(formatBandwidth(txRate))"
        } else {
            wifiItems[7].title = "  Download: —"
            wifiItems[8].title = "  Upload:   —"
        }
        if let (rx, tx) = interfaceBytesRxTx(iface.interfaceName ?? "") {
            bwLastRx = rx; bwLastTx = tx; bwLastTime = now
        }

        let sumOut = NSMutableAttributedString(string: "  \(iface.ssid() ?? "—")  \(pct)% ")
        sumOut.append(colorMeter(pct: pct, inverted: false))
        wifiSummary.attributedTitle = sumOut

        updateTitle(rssi: rssi, pct: pct, maxCoreTemp: nil)
    }

    // MARK: CPU

    func refreshCPU() {
        let cores = smc?.coreTemperatures() ?? []
        if cores.isEmpty {
            cpuItems[0].title = "  Temp: unavailable"
            cpuItems[0].attributedTitle = nil
            cpuSummary.title = "  Temp: unavailable"; cpuSummary.attributedTitle = nil
        } else {
            for (i, core) in cores.enumerated() {
                let t = Int(core.temp.rounded())
                cpuItems[i].attributedTitle = tempLine(label: core.label, temp: t, pct: cpuTempPercent(t))
            }
            let maxT = Int(cores[0].temp.rounded())
            cpuSummary.attributedTitle = tempLine(label: "Temp", temp: maxT, pct: cpuTempPercent(maxT))
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
            batItems[0].attributedTitle = tempLine(label: "Temp", temp: temp, pct: batteryTempPercent(temp))
        } else {
            batItems[0].title = "  Temp: unavailable"
            batItems[0].attributedTitle = nil
        }
        // Rows 1 & 2: cycle count and charge level from IOKit registry
        let info = smc?.batteryRegistryInfo()
        if let cycles = info?.cycles {
            batItems[1].title = "  Cycle count: \(cycles)"
        } else {
            batItems[1].title = "  Cycle count: unavailable"
        }
        if let pct = info?.chargePct {
            let out = NSMutableAttributedString(string: "  Charge: \(pct)% ")
            out.append(colorMeter(pct: pct, inverted: false))
            batItems[2].attributedTitle = out
            let sum = NSMutableAttributedString(string: "  Charge: \(pct)% ")
            sum.append(colorMeter(pct: pct, inverted: false))
            batSummary.attributedTitle = sum
        } else {
            batItems[2].title = "  Charge: unavailable"
            batItems[2].attributedTitle = nil
            batSummary.title = "  Charge: unavailable"
            batSummary.attributedTitle = nil
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

    // MARK: Disk

    func refreshDisk() {
        let info = diskReader.read()
        diskItems[0].title = "  Drive:      \(info?.name ?? "unavailable")"
        diskItems[1].title = "  S.M.A.R.T.: \(info?.smartStatus ?? "—")"
        if let t = smc?.storageTemperature() {
            let temp = Int(t.rounded())
            diskItems[2].attributedTitle = tempLine(label: "Temp", temp: temp, pct: diskTempPercent(temp))
        } else {
            diskItems[2].title = "  Temp: —"
            diskItems[2].attributedTitle = nil
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(diskLastTime)
        var readRate: Double = 0, writeRate: Double = 0
        if let rx = info?.bytesRead, let tx = info?.bytesWritten,
           diskLastTime != .distantPast, elapsed > 0, rx >= diskLastRx, tx >= diskLastTx {
            readRate  = Double(rx - diskLastRx) / elapsed
            writeRate = Double(tx - diskLastTx) / elapsed
        }
        if let rx = info?.bytesRead, let tx = info?.bytesWritten {
            diskLastRx = rx; diskLastTx = tx; diskLastTime = now
        }
        diskGraph.push(read: readRate, write: writeRate)

        diskItems[3].title = "  Lifetime read:    \(info?.bytesRead.map(formatDiskBytes)    ?? "—")"
        diskItems[4].title = "  Lifetime written: \(info?.bytesWritten.map(formatDiskBytes) ?? "—")"
    }

    // 20°C (idle) = 0%, 60°C (hot) = 100%
    func diskTempPercent(_ temp: Int) -> Int {
        let c = max(20, min(60, temp))
        return (c - 20) * 100 / 40
    }

    private func formatDiskBytes(_ bytes: UInt64) -> String {
        let tb = Double(bytes) / 1e12
        let gb = Double(bytes) / 1e9
        if tb >= 1 { return String(format: "%.1f TB", tb) }
        return String(format: "%.0f GB", gb)
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
            out.append(NSAttributedString(string: " │ \(formatTemp(t))"))
        }
        statusItem.button?.attributedTitle = out
    }

    // MARK: Shared helpers

    func toggleDisk() {
        diskCollapsed.toggle()
        diskHeaderView.isCollapsed = diskCollapsed
        diskItems.forEach { $0.isHidden = diskCollapsed }
    }

    func toggleBat() {
        batCollapsed.toggle()
        batHeaderView.isCollapsed = batCollapsed
        applyCollapse(summary: batSummary, details: batItems, collapsed: batCollapsed)
    }

    func toggleWifi() {
        wifiCollapsed.toggle()
        wifiHeaderView.isCollapsed = wifiCollapsed
        applyCollapse(summary: wifiSummary, details: wifiItems, collapsed: wifiCollapsed)
    }

    func toggleCPU() {
        cpuCollapsed.toggle()
        cpuHeaderView.isCollapsed = cpuCollapsed
        applyCollapse(summary: cpuSummary, details: cpuItems, collapsed: cpuCollapsed)
    }

    @objc func toggleTempUnit() {
        useFahrenheit.toggle()
        unitItem.state = useFahrenheit ? .on : .off
        refresh()
    }

    func formatTemp(_ celsius: Int) -> String {
        useFahrenheit ? "\(celsius * 9 / 5 + 32)°F" : "\(celsius)°C"
    }

    // 30°C (idle) = 0%, 100°C (throttle) = 100%
    func cpuTempPercent(_ temp: Int) -> Int {
        let c = max(30, min(100, temp))
        return (c - 30) * 100 / 70
    }

    // 20°C (normal) = 0%, 50°C (hot) = 100%
    func batteryTempPercent(_ temp: Int) -> Int {
        let c = max(20, min(50, temp))
        return (c - 20) * 100 / 30
    }

    func tempLine(label: String, temp: Int, pct: Int) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "  \(label): \(formatTemp(temp)) (\(pct)%) ")
        out.append(colorMeter(pct: pct, inverted: true))
        return out
    }

    private func interfaceBytesRxTx(_ name: String) -> (rx: UInt64, tx: UInt64)? {
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard String(cString: cur.pointee.ifa_name) == name,
                  let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = cur.pointee.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            return (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
        }
        return nil
    }

    private func formatBandwidth(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1_024         { return "< 1 KB/s" }
        if bytesPerSec < 1_048_576     { return String(format: "%.0f KB/s", bytesPerSec / 1_024) }
        return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
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
