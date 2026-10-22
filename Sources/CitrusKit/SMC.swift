import CSMC
import Foundation

/// A raw value read from the System Management Controller.
public struct SMCValue: Sendable, Equatable {
    /// Four-character SMC data type, e.g. `"flt "`, `"ui16"`, `"sp78"`.
    public let type: String
    public let bytes: [UInt8]

    public init(type: String, bytes: [UInt8]) {
        self.type = type
        self.bytes = bytes
    }

    /// Numeric interpretation of the value.
    ///
    /// Apple Silicon SMCs return integers little-endian; Intel SMCs return them
    /// big-endian. Floats (`flt `) are always little-endian. Fixed-point types
    /// (`sp78`, `fpe2`) only exist on Intel and are big-endian.
    public func doubleValue(littleEndianIntegers: Bool = SMCValue.hostUsesLittleEndianIntegers) -> Double? {
        func unsigned(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            let slice = bytes.prefix(count)
            let ordered = littleEndianIntegers ? Array(slice.reversed()) : Array(slice)
            return ordered.reduce(0) { ($0 << 8) | UInt64($1) }
        }

        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "flag": return unsigned(1).map { Double($0) }
        case "ui16": return unsigned(2).map { Double($0) }
        case "ui32": return unsigned(4).map { Double($0) }
        case "ui64": return unsigned(8).map { Double($0) }
        case "si8 ": return unsigned(1).map { Double(Int8(truncatingIfNeeded: $0)) }
        case "si16": return unsigned(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "si32": return unsigned(4).map { Double(Int32(truncatingIfNeeded: $0)) }
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }

    /// Text interpretation for `ch8*` values, trimmed at the first NUL.
    public var stringValue: String? {
        guard type == "ch8*" else { return nil }
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    public static var hostUsesLittleEndianIntegers: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}

/// Anything that can look up SMC keys. Lets tests substitute fixed values.
public protocol SMCReading: Sendable {
    func read(_ key: String) -> SMCValue?
}

extension SMCReading {
    public func double(_ key: String) -> Double? {
        read(key)?.doubleValue()
    }

    /// The first key in `keys` that returns a value.
    public func double(firstOf keys: [String]) -> Double? {
        for key in keys {
            if let value = double(key) { return value }
        }
        return nil
    }
}

/// Live connection to the AppleSMC kernel service.
public final class SMC: SMCReading, @unchecked Sendable {
    public static let shared = SMC()

    private let lock = NSLock()
    private var connection: csmc_connection = 0

    public init() {}

    deinit {
        csmc_close(connection)
    }

    public func read(_ key: String) -> SMCValue? {
        let utf8 = Array(key.utf8)
        guard utf8.count == 4 else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if connection == 0 {
            connection = csmc_open()
            if connection == 0 { return nil }
        }

        var type = [CChar](repeating: 0, count: 4)
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        let keyChars = utf8.map { CChar(bitPattern: $0) }
        let ok = csmc_read(connection, keyChars, &type, &bytes, &size)
        guard ok else { return nil }

        let typeString = String(decoding: type.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return SMCValue(type: typeString, bytes: Array(bytes.prefix(Int(size))))
    }
}

/// SMC keys used by Citrus Battery.
public enum SMCKey {
    /// Total system power draw (W).
    public static let systemPower = "PSTR"
    /// Power delivered by the adapter (W).
    public static let adapterPower = "PDTR"
    public static let adapterVoltage = "VD0R"
    public static let adapterCurrent = "ID0R"
    public static let batteryTemperature = "TB0T"
    public static let batteryVoltage = "B0AV"
    public static let batteryCurrent = "B0AC"
    public static let fullChargeCapacity = "B0FC"
    public static let designCapacity = "B0DC"
    public static let cycleCount = "B0CT"
    /// Remaining capacity; `SBAR` is the alternate key on some machines.
    public static let remainingCapacity = ["B0RM", "SBAR"]
    /// Relative state of charge (%); `SBAS` is the alternate key.
    public static let stateOfCharge = ["BRSC", "SBAS"]
    /// Battery serial number (text).
    public static let batterySerial = "BMSN"
    /// Battery manufacture week, e.g. "330802" (text; Apple Silicon).
    public static let batteryManufactureWeek = "BMDT"
    /// Per-cell voltages (mV), as many as the pack has.
    public static let cellVoltages = ["BC1V", "BC2V", "BC3V", "BC4V"]
    /// CPU temperature candidates, Apple Silicon first.
    public static let cpuTemperature = ["Tp0C", "Tp01", "Tp05", "Tp09", "TC0P", "TC0D", "TC0E"]
}
