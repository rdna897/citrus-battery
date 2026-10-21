import CryptoKit
import Foundation

/// Reads history backups in the `.ccba` format.
///
/// A backup is an AES-GCM sealed box (nonce, ciphertext, tag) whose plaintext is
/// LZFSE-compressed JSON: an array of entries keyed like `"Battery.FCC"`. The
/// encryption key is embedded in the app that wrote the backup. Citrus Battery doesn't
/// ship that key; it reads candidates from that installed app and lets AES-GCM's
/// authentication tag identify the right one.
public enum CoconutBatteryBackup {
    public enum ImportError: Error, LocalizedError {
        case appNotFound
        case noMatchingKey
        case unreadableContents

        public var errorDescription: String? {
            switch self {
            case .appNotFound:
                "Importing a coconutBattery backup needs coconutBattery installed in Applications, "
                    + "because the backup is encrypted with a key built into that app."
            case .noMatchingKey:
                "This file couldn't be decrypted with the installed coconutBattery. It may be damaged, "
                    + "or made by a different coconutBattery version."
            case .unreadableContents:
                "The backup was decrypted, but its contents weren't in the expected format."
            }
        }
    }

    public static let defaultAppURL = URL(fileURLWithPath: "/Applications/coconutBattery.app")

    /// Decodes a backup using keys found in the installed app that wrote it.
    public static func entries(from backup: Data, appURL: URL = defaultAppURL) throws -> [HistoryEntry] {
        let executable = appURL.appendingPathComponent("Contents/MacOS/coconutBattery")
        guard let binary = try? Data(contentsOf: executable, options: .mappedIfSafe) else {
            throw ImportError.appNotFound
        }
        return try entries(from: backup, keyCandidates: keyCandidates(in: binary))
    }

    /// Decodes a backup, trying each candidate key.
    public static func entries(from backup: Data, keyCandidates: [SymmetricKey]) throws -> [HistoryEntry] {
        guard let box = try? AES.GCM.SealedBox(combined: backup) else { throw ImportError.noMatchingKey }
        guard let compressed = keyCandidates.lazy.compactMap({ try? AES.GCM.open(box, using: $0) }).first else {
            throw ImportError.noMatchingKey
        }
        guard let json = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let records = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]]
        else { throw ImportError.unreadableContents }
        return records.compactMap(entry(from:))
    }

    /// Base64 strings in `binary` that decode to 256-bit keys.
    public static func keyCandidates(in binary: Data) -> [SymmetricKey] {
        var keys: [SymmetricKey] = []
        var seen = Set<Data>()
        var run: [UInt8] = []

        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.count == 44, run.last == UInt8(ascii: "="),
                  let decoded = Data(base64Encoded: Data(run)), decoded.count == 32,
                  seen.insert(decoded).inserted
            else { return }
            keys.append(SymmetricKey(data: decoded))
        }

        for byte in binary {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="):
                run.append(byte)
                if run.count > 44 { run.removeAll(keepingCapacity: true) }
            default:
                flush()
            }
        }
        flush()
        return keys
    }

    /// Drops capacities that can't be mAh values. Some backups (data version 4.0,
    /// macOS 27) saved full charge = 100 (a percentage) and design = -1 (missing).
    static func plausibleCapacities(design: Int?, fullCharge: Int?) -> (design: Int?, fullCharge: Int?) {
        let design = design.flatMap { $0 > 100 ? $0 : nil }
        let fullCharge = fullCharge.flatMap { $0 > 100 ? $0 : nil }
        return (design, fullCharge)
    }

    /// Converts one backup record; skips records without a device serial or date.
    static func entry(from record: [String: Any]) -> HistoryEntry? {
        guard let serial = record["Device.Serial"] as? String, !serial.isEmpty,
              let timestamp = (record["Data.SnapshotDate"] as? NSNumber)?.doubleValue
        else { return nil }
        func int(_ key: String) -> Int? { (record[key] as? NSNumber)?.intValue }
        let (design, fullCharge) = plausibleCapacities(design: int("Battery.DC"), fullCharge: int("Battery.FCC"))
        let type = (record["Data.Type"] as? String)?.lowercased() == "mac" ? HistoryEntry.DeviceType.mac : .iOS
        return HistoryEntry(
            date: Date(timeIntervalSince1970: timestamp),
            deviceType: type,
            deviceSerial: serial,
            deviceName: record["Device.Name"] as? String ?? "",
            deviceModel: record["Device.Model"] as? String ?? "",
            osVersion: record["Device.OSVersion"] as? String,
            batterySerial: record["Battery.Serial"] as? String,
            cycleCount: int("Battery.CycleCount"),
            designCapacity: design,
            fullChargeCapacity: fullCharge,
            comment: (record["Data.Version"] as? String).map { "Imported from coconutBattery \($0)" }
        )
    }
}
