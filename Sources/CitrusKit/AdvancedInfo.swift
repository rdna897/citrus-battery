import AppKit
import CoreGraphics
import CSMC
import Foundation
import IOKit

/// A row in the Advanced Viewer: a key, an optional value, and optional children.
public struct InfoNode: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var value: String?
    public var children: [InfoNode]?

    public init(_ title: String, _ value: String? = nil, children: [InfoNode]? = nil, path: String = "") {
        self.id = path.isEmpty ? title : "\(path)/\(title)"
        self.title = title
        self.value = value
        self.children = children
    }

    /// Tab-separated "key\tvalue" lines for this node and its descendants, indented by depth.
    public func tabSeparated(depth: Int = 0) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var lines = ["\(indent)\(title)\t\(value ?? "")"]
        for child in children ?? [] {
            lines += child.tabSeparated(depth: depth + 1)
        }
        return lines
    }

    /// Converts a property-list value into a tree, sorting dictionary keys.
    public static func tree(_ title: String, _ value: Any, path: String = "") -> InfoNode {
        let id = path.isEmpty ? title : "\(path)/\(title)"
        switch value {
        case let dictionary as [String: Any]:
            let children = dictionary.keys.sorted().map { tree($0, dictionary[$0]!, path: id) }
            return InfoNode(title, items(dictionary.count), children: children, path: path)
        case let array as [Any]:
            let children = array.enumerated().map { tree("[\($0.offset)]", $0.element, path: id) }
            return InfoNode(title, items(array.count), children: children, path: path)
        default:
            return InfoNode(title, describe(value), path: path)
        }
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let data as Data:
            let hex = data.prefix(24).map { String(format: "%02x", $0) }.joined()
            return data.count > 24 ? "\(hex)… (\(data.count) bytes)" : hex
        case let date as Date:
            return date.formatted(date: .abbreviated, time: .standard)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue ? "Yes" : "No"
        default:
            return String(describing: value)
        }
    }
}

/// NVMe SMART health of one drive.
public struct DriveHealth: Sendable, Equatable {
    public var model: String
    public var serial: String
    public var firmware: String
    public var percentageUsed: Int
    public var availableSpare: Int
    public var availableSpareThreshold: Int
    public var temperatureCelsius: Int
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var powerOnHours: UInt64
    public var powerCycles: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64
    public var criticalWarning: Int

    /// Every SMART-capable NVMe drive (internal and external).
    public static func readAll() -> [DriveHealth] {
        var drives = [cnvme_health](repeating: cnvme_health(), count: 8)
        let count = Int(cnvme_read_all(&drives, Int32(drives.count)))
        return drives.prefix(count).map { d in
            var copy = d
            func text<T>(_ tuple: inout T) -> String {
                withUnsafeBytes(of: &tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    .trimmingCharacters(in: .whitespaces)
            }
            // NVMe "data units" are 1,000 × 512 bytes.
            return DriveHealth(
                model: text(&copy.model), serial: text(&copy.serial), firmware: text(&copy.firmware),
                percentageUsed: Int(d.percentage_used), availableSpare: Int(d.available_spare),
                availableSpareThreshold: Int(d.available_spare_threshold),
                temperatureCelsius: Int(d.temperature_celsius),
                bytesRead: d.data_units_read &* 512_000, bytesWritten: d.data_units_written &* 512_000,
                powerOnHours: d.power_on_hours, powerCycles: d.power_cycles,
                unsafeShutdowns: d.unsafe_shutdowns, mediaErrors: d.media_errors,
                criticalWarning: Int(d.critical_warning))
        }
    }
}

/// Builds the Advanced Viewer trees.
public enum AdvancedInfo {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
    }

    // MARK: Mac

    /// Everything about the Mac. Reading SSD health can take a while (an external
    /// drive may be slow to answer), so the app builds this in the background and
    /// passes in `displays`, read on the main thread, where NSScreen must be used.
    public static func mac(info: MacInfo, marketingName: String?, displays: InfoNode? = nil) -> [InfoNode] {
        var sections = [macSection(info: info, marketingName: marketingName)]
        if let registry = MacBatteryReader.registryProperties() {
            sections.append(tree("Battery (AppleSmartBattery)", registry.filter { !ignoredKeys.contains($0.key) }))
        }
        if let pack = MacBatteryReader.packBatteryData() {
            sections.append(tree("Battery Pack (BatteryData)", pack))
        }
        sections.append(storageSection())
        sections.append(displays ?? displaySection())
        sections.append(usbSection())
        return sections
    }

    /// Registry keys that are noise in the viewer (large, opaque or internal).
    static let ignoredKeys: Set<String> = ["IOReportLegend", "IOGeneralInterest", "IOReportLegendPublic"]

    static func macSection(info: MacInfo, marketingName: String?) -> InfoNode {
        let process = ProcessInfo.processInfo
        let uptime = info.bootDate.map { Date().timeIntervalSince($0) } ?? process.systemUptime
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        let rows: [InfoNode] = [
            InfoNode("Model", marketingName, path: "Mac"),
            InfoNode("Model identifier", info.modelIdentifier, path: "Mac"),
            InfoNode("Model number", info.modelNumber, path: "Mac"),
            InfoNode("Chip", info.chip, path: "Mac"),
            InfoNode("Serial number", info.serialNumber, path: "Mac"),
            InfoNode("Manufactured", info.manufactureDate.flatMap { Calendar.current.date(from: $0) }?
                .formatted(date: .abbreviated, time: .omitted), path: "Mac"),
            InfoNode("macOS", info.osVersion, path: "Mac"),
            InfoNode("Booted", info.bootDate?.formatted(date: .abbreviated, time: .shortened), path: "Mac"),
            InfoNode("Time since boot", DurationFormat.readable(Int(uptime / 60)), path: "Mac"),
            InfoNode("Thermal state", thermal, path: "Mac"),
            InfoNode("Low Power Mode", process.isLowPowerModeEnabled ? "On" : "Off", path: "Mac"),
        ]
        return InfoNode("Mac", info.modelIdentifier, children: rows.filter { $0.value != nil })
    }

    static func storageSection() -> InfoNode {
        let drives = DriveHealth.readAll()
        let statistics = blockStorageStatistics()
        let children = drives.map { drive -> InfoNode in
            let path = "Storage/\(drive.model)"
            var rows = [
                InfoNode("Serial number", drive.serial, path: path),
                InfoNode("Firmware", drive.firmware, path: path),
                InfoNode("Life used", "\(drive.percentageUsed)%", path: path),
                InfoNode("Available spare", "\(drive.availableSpare)% (threshold \(drive.availableSpareThreshold)%)", path: path),
                InfoNode("Temperature", "\(drive.temperatureCelsius) °C", path: path),
                InfoNode("Data read", bytes(drive.bytesRead), path: path),
                InfoNode("Data written", bytes(drive.bytesWritten), path: path),
                InfoNode("Power-on hours", "\(drive.powerOnHours)", path: path),
                InfoNode("Power cycles", "\(drive.powerCycles)", path: path),
                InfoNode("Unsafe shutdowns", "\(drive.unsafeShutdowns)", path: path),
                InfoNode("Media errors", "\(drive.mediaErrors)", path: path),
                InfoNode("Critical warning", drive.criticalWarning == 0 ? "None" : "0x\(String(drive.criticalWarning, radix: 16))", path: path),
            ]
            if let stats = statistics[drive.serial] {
                rows += [
                    InfoNode("Read since boot", stats.read.map(bytes), path: path),
                    InfoNode("Written since boot", stats.written.map(bytes), path: path),
                    InfoNode("Read errors since boot", stats.readErrors.map(String.init), path: path),
                    InfoNode("Write errors since boot", stats.writeErrors.map(String.init), path: path),
                ].filter { $0.value != nil }
            }
            return InfoNode(drive.model, bytes(drive.bytesWritten) + " written", children: rows, path: "Storage")
        }
        return InfoNode("Storage", "\(drives.count) drive\(drives.count == 1 ? "" : "s")", children: children)
    }

    struct BlockStatistics {
        var read: UInt64?
        var written: UInt64?
        var readErrors: Int?
        var writeErrors: Int?
    }

    /// IOBlockStorageDriver statistics (since boot), keyed by the drive serial number.
    static func blockStorageStatistics() -> [String: BlockStatistics] {
        var result: [String: BlockStatistics] = [:]
        forEachService(className: "IOBlockStorageDriver") { service in
            guard let stats = property(service, "Statistics") as? [String: Any] else { return }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(parent) }
            let characteristics = property(parent, "Device Characteristics") as? [String: Any]
            guard let serial = (characteristics?["Serial Number"] as? String)?.trimmingCharacters(in: .whitespaces)
            else { return }
            func number(_ key: String) -> UInt64? { (stats[key] as? NSNumber)?.uint64Value }
            result[serial] = BlockStatistics(
                read: number("Bytes (Read)"), written: number("Bytes (Write)"),
                readErrors: number("Errors (Read)").map { Int($0) }, writeErrors: number("Errors (Write)").map { Int($0) })
        }
        return result
    }

    static func usbSection() -> InfoNode {
        var devices: [InfoNode] = []
        forEachService(className: "IOUSBHostDevice") { service in
            let name = property(service, "USB Product Name") as? String
                ?? property(service, "kUSBProductString") as? String ?? "USB device"
            let path = "USB/\(name)-\(devices.count)"
            let speed = (property(service, "Device Speed") as? NSNumber).map { usbSpeed($0.intValue) }
            let rows = [
                InfoNode("Vendor", property(service, "USB Vendor Name") as? String
                    ?? property(service, "kUSBVendorString") as? String, path: path),
                InfoNode("Serial number", property(service, "USB Serial Number") as? String
                    ?? property(service, "kUSBSerialNumberString") as? String, path: path),
                InfoNode("Speed", speed, path: path),
                InfoNode("Product ID", (property(service, "idProduct") as? NSNumber).map { String(format: "0x%04x", $0.intValue) }, path: path),
                InfoNode("Vendor ID", (property(service, "idVendor") as? NSNumber).map { String(format: "0x%04x", $0.intValue) }, path: path),
            ].filter { $0.value != nil }
            devices.append(InfoNode(name, speed, children: rows, path: "USB/\(devices.count)"))
        }
        return InfoNode("USB Devices", "\(devices.count)", children: devices)
    }

    /// IOUSBHostDevice "Device Speed" values.
    static func usbSpeed(_ value: Int) -> String {
        switch value {
        case 0: "USB 1.1 Low Speed (1.5 Mb/s)"
        case 1: "USB 1.1 Full Speed (12 Mb/s)"
        case 2: "USB 2.0 High Speed (480 Mb/s)"
        case 3: "USB 3 SuperSpeed (5 Gb/s)"
        case 4: "USB 3 SuperSpeed+ (10 Gb/s)"
        case 5: "USB 3 SuperSpeed+ (20 Gb/s)"
        default: "Unknown speed (\(value))"
        }
    }

    /// Connected displays via CoreGraphics; names from NSScreen.
    public static func displaySection() -> InfoNode {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })

        let children = ids.prefix(Int(count)).enumerated().map { index, id -> InfoNode in
            let path = "Displays/\(index)"
            let mode = CGDisplayCopyDisplayMode(id)
            let size = CGDisplayScreenSize(id) // millimetres
            let diagonal = sqrt(size.width * size.width + size.height * size.height) / 25.4
            let rows = [
                InfoNode("Type", CGDisplayIsBuiltin(id) != 0 ? "Built-in" : "External", path: path),
                InfoNode("Resolution", mode.map { "\($0.pixelWidth) × \($0.pixelHeight) pixels" }, path: path),
                InfoNode("Looks like", mode.map { "\($0.width) × \($0.height)" }, path: path),
                InfoNode("Refresh rate", mode.flatMap { $0.refreshRate > 0 ? String(format: "%.0f Hz", $0.refreshRate) : nil }, path: path),
                InfoNode("Size", size.width > 0 ? String(format: "%.1f-inch (%.0f × %.0f mm)", diagonal, size.width, size.height) : nil, path: path),
                InfoNode("Vendor ID", String(format: "0x%04x", CGDisplayVendorNumber(id)), path: path),
                InfoNode("Model ID", String(format: "0x%04x", CGDisplayModelNumber(id)), path: path),
                InfoNode("Serial number", CGDisplaySerialNumber(id) != 0 ? "\(CGDisplaySerialNumber(id))" : nil, path: path),
            ].filter { $0.value != nil }
            return InfoNode(names[id] ?? "Display \(index + 1)", rows.first?.value, children: rows, path: "Displays")
        }
        return InfoNode("Displays", "\(children.count)", children: children)
    }

    static func registryList(_ title: String, className: String, keys: [String]) -> InfoNode {
        var items: [InfoNode] = []
        forEachService(className: className) { service in
            let path = "\(title)/\(items.count)"
            let rows = keys.compactMap { key -> InfoNode? in
                property(service, key).map { InfoNode(key, InfoNode.describe($0), path: path) }
            }
            guard !rows.isEmpty else { return }
            let name = rows.first?.value ?? "\(className) \(items.count + 1)"
            items.append(InfoNode(name, nil, children: rows, path: path))
        }
        return InfoNode(title, "\(items.count)", children: items)
    }

    // MARK: iPhone / iPad

    public static func device(info: [String: Any]?, battery: [String: Any]?, pack: [String: Any]?) -> [InfoNode] {
        var sections: [InfoNode] = []
        if let info { sections.append(tree("Device", info)) }
        if let battery {
            let registry = battery["IORegistry"] as? [String: Any] ?? battery
            sections.append(tree("Battery (IOPMPowerSource)", registry.filter { !ignoredKeys.contains($0.key) }))
        }
        if let pack {
            let registry = pack["IORegistry"] as? [String: Any] ?? pack
            sections.append(tree("Battery Pack (AppleSmartBatteryPack)", registry))
        }
        return sections
    }

    // MARK: Helpers

    static func tree(_ title: String, _ dictionary: [String: Any]) -> InfoNode {
        InfoNode.tree(title, dictionary)
    }

    static func forEachService(className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
