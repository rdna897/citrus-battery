import CIDevice
import Foundation

/// One read of an iPhone or iPad.
public struct IOSDeviceSnapshot: Sendable, Equatable, Identifiable {
    public enum Connection: String, Sendable { case usb, wifi }

    public var udid: String
    public var connection: Connection
    public var date: Date
    /// The name the user gave the device, e.g. "Safwan's iPhone".
    public var name: String
    /// Model identifier, e.g. "iPhone16,1".
    public var productType: String
    /// e.g. "iPhone 15 Pro".
    public var marketingName: String
    public var osVersion: String?
    public var serialNumber: String?
    /// e.g. "MTUV3B/A".
    public var modelNumber: String?
    public var battery: MacBatterySnapshot?

    public var id: String { udid }

    public var deviceClass: String {
        productType.hasPrefix("iPad") ? "iPad" : productType.hasPrefix("Watch") ? "Apple Watch" : "iPhone"
    }
}

extension IOSDeviceSnapshot {
    /// Builds a snapshot from lockdown values, the diagnostics IORegistry reply and
    /// the MobileGestalt reply (each as decoded property lists).
    public init(udid: String, connection: Connection, info: [String: Any], battery: [String: Any]?,
                gestalt: [String: Any]?, date: Date = Date()) {
        let gestaltValues = gestalt?["MobileGestalt"] as? [String: Any] ?? gestalt ?? [:]
        let registry = battery?["IORegistry"] as? [String: Any] ?? battery

        self.udid = udid
        self.connection = connection
        self.date = date
        productType = info["ProductType"] as? String ?? gestaltValues["ProductType"] as? String ?? "iOS device"
        name = info["DeviceName"] as? String ?? productType
        marketingName = gestaltValues["MarketingName"] as? String
            ?? IOSModelNames.name(for: productType) ?? productType
        osVersion = info["ProductVersion"] as? String
        serialNumber = info["SerialNumber"] as? String ?? gestaltValues["SerialNumber"] as? String
        let number = info["ModelNumber"] as? String ?? gestaltValues["ModelNumber"] as? String
        let region = info["RegionInfo"] as? String ?? gestaltValues["RegionInfo"] as? String
        modelNumber = number.map { $0 + (region ?? "") }
        self.battery = registry.flatMap { $0.isEmpty ? nil : MacBatterySnapshot(registry: $0, smc: nil, powerSource: nil, date: date) }
    }
}

public enum IOSDeviceStatus: Sendable, Equatable {
    case ready(IOSDeviceSnapshot)
    /// Waiting for "Trust This Computer", or trust was refused.
    case notTrusted
    /// Locked with a passcode; unlock it once to allow reading.
    case locked
    case unavailable
}

/// Talks to connected iPhones and iPads through libimobiledevice (usbmuxd).
public enum IOSDeviceReader {
    public struct Listing: Sendable, Equatable {
        public var udid: String
        public var connection: IOSDeviceSnapshot.Connection
    }

    /// Devices currently visible over USB, or over WiFi when "Show this iPhone when
    /// on Wi-Fi" is enabled in Finder.
    public static func connectedDevices() -> [Listing] {
        var devices = [cid_device](repeating: cid_device(), count: 32)
        let count = Int(cid_list_devices(&devices, Int32(devices.count)))
        return devices.prefix(count).map { device in
            var udid = device.udid
            let text = withUnsafeBytes(of: &udid) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return Listing(udid: text, connection: device.network ? .wifi : .usb)
        }
    }

    /// Reads one device. Blocking (network round trips); call off the main thread.
    public static func read(_ listing: Listing) -> IOSDeviceStatus {
        var payload = cid_payload()
        let status = cid_read(listing.udid, listing.connection == .wifi, &payload)
        defer { cid_free_payload(&payload) }

        switch status {
        case CID_OK:
            guard let info = plist(payload.info, payload.info_length) else { return .unavailable }
            return .ready(IOSDeviceSnapshot(
                udid: listing.udid, connection: listing.connection, info: info,
                battery: plist(payload.battery, payload.battery_length),
                gestalt: plist(payload.gestalt, payload.gestalt_length)))
        case CID_NOT_TRUSTED: return .notTrusted
        case CID_LOCKED: return .locked
        default: return .unavailable
        }
    }

    private static func plist(_ bytes: UnsafeMutablePointer<UInt8>?, _ length: UInt32) -> [String: Any]? {
        guard let bytes, length > 0 else { return nil }
        let data = Data(bytes: bytes, count: Int(length))
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// Marketing names for model identifiers, used when the device doesn't report one.
/// Only well-established identifiers are listed; others fall back to the identifier.
public enum IOSModelNames {
    private static let names: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
    ]

    public static func name(for productType: String) -> String? {
        names[productType]
    }
}
