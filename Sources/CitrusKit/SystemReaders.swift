import Foundation
import IOKit
import IOKit.ps

/// Reads the `AppleSmartBattery` registry entry and macOS power-source info.
public enum MacBatteryReader {
    /// Current battery state, or `nil` when the Mac has no internal battery.
    public static func read(smc: SMCReading? = SMC.shared) -> MacBatterySnapshot? {
        guard let registry = registryProperties(), (registry["BatteryInstalled"] as? Bool) != false else {
            return nil
        }
        return MacBatterySnapshot(registry: registry, smc: smc, powerSource: powerSourceInfo())
    }

    public static func registryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dictionary
    }

    public static func powerSourceInfo() -> PowerSourceInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            var result = PowerSourceInfo()
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                result.chargePercent = Int((Double(current) / Double(max) * 100).rounded())
            }
            result.timeToEmptyMinutes = (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            result.timeToFullMinutes = (description[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            result.healthDescription = description["BatteryHealthCondition"] as? String
                ?? description[kIOPSBatteryHealthKey] as? String
            return result
        }
        return nil
    }
}

/// Instantaneous power and thermal readings from the SMC.
public struct PowerReadings: Sendable, Equatable {
    /// Whole-system power draw (W).
    public var systemWatts: Double?
    /// Power arriving from the adapter (W).
    public var adapterWatts: Double?
    public var adapterVolts: Double?
    public var adapterAmps: Double?
    public var cpuTemperatureCelsius: Double?

    public init(systemWatts: Double? = nil, adapterWatts: Double? = nil, adapterVolts: Double? = nil,
                adapterAmps: Double? = nil, cpuTemperatureCelsius: Double? = nil) {
        self.systemWatts = systemWatts
        self.adapterWatts = adapterWatts
        self.adapterVolts = adapterVolts
        self.adapterAmps = adapterAmps
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
    }

    public static func read(smc: SMCReading = SMC.shared) -> PowerReadings {
        PowerReadings(
            systemWatts: smc.double(SMCKey.systemPower),
            adapterWatts: smc.double(SMCKey.adapterPower),
            adapterVolts: smc.double(SMCKey.adapterVoltage),
            adapterAmps: smc.double(SMCKey.adapterCurrent),
            cpuTemperatureCelsius: smc.double(firstOf: SMCKey.cpuTemperature)
        )
    }
}

/// Static facts about this Mac.
public struct MacInfo: Sendable, Equatable {
    /// e.g. "Mac16,12".
    public var modelIdentifier: String
    /// e.g. "MW123B/A".
    public var modelNumber: String?
    public var serialNumber: String?
    public var chip: String?
    public var osVersion: String
    public var bootDate: Date?

    public static func read() -> MacInfo {
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if platform != IO_OBJECT_NULL { IOObjectRelease(platform) } }

        func property(_ key: String) -> Any? {
            guard platform != IO_OBJECT_NULL else { return nil }
            return IORegistryEntryCreateCFProperty(platform, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        func string(_ key: String) -> String? {
            switch property(key) {
            case let s as String: return s
            case let d as Data: return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
            default: return nil
            }
        }

        let modelNumber = [string("model-number"), string("region-info")].compactMap { $0 }.joined()
        return MacInfo(
            modelIdentifier: sysctlString("hw.model") ?? string("model") ?? "Mac",
            modelNumber: modelNumber.isEmpty ? nil : modelNumber,
            serialNumber: string(kIOPlatformSerialNumberKey),
            chip: sysctlString("machdep.cpu.brand_string"),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            bootDate: bootDate()
        )
    }

    /// Marketing name such as "MacBook Air", via `system_profiler`. Slow (~1 s); call off the main thread.
    public static func marketingName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hardware = (json["SPHardwareDataType"] as? [[String: Any]])?.first
        else { return nil }
        return hardware["machine_name"] as? String
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func bootDate() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }
}
