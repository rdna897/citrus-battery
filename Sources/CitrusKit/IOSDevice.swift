import CIDevice
import Foundation
import UniformTypeIdentifiers

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
    ///
    /// `pack` is the `AppleSmartBatteryPack` reply; as on the Mac, its `BatteryData`
    /// holds temperature and lifetime data the main entry lacks.
    public init(udid: String, connection: Connection, info: [String: Any], battery: [String: Any]?,
                pack: [String: Any]? = nil, gestalt: [String: Any]?, date: Date = Date()) {
        let gestaltValues = gestalt?["MobileGestalt"] as? [String: Any] ?? gestalt ?? [:]
        let registry = battery?["IORegistry"] as? [String: Any] ?? battery
        let packRegistry = pack?["IORegistry"] as? [String: Any] ?? pack

        self.udid = udid
        self.connection = connection
        self.date = date
        productType = info["ProductType"] as? String ?? gestaltValues["ProductType"] as? String ?? "iOS device"
        name = info["DeviceName"] as? String ?? productType
        marketingName = gestaltValues["MarketingName"] as? String
            ?? DeviceModels.name(for: productType) ?? productType
        osVersion = info["ProductVersion"] as? String
        serialNumber = info["SerialNumber"] as? String ?? gestaltValues["SerialNumber"] as? String
        let number = info["ModelNumber"] as? String ?? gestaltValues["ModelNumber"] as? String
        let region = info["RegionInfo"] as? String ?? gestaltValues["RegionInfo"] as? String
        modelNumber = number.map { $0 + (region ?? "") }
        let packData = packRegistry?["BatteryData"] as? [String: Any]
        self.battery = registry.flatMap {
            $0.isEmpty ? nil : MacBatterySnapshot(registry: $0, pack: packData, smc: nil, powerSource: nil, date: date)
        }
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
    ///
    /// For WiFi devices whose usbmuxd address doesn't answer, retries at the
    /// device's current IPv4 address, found on Bonjour by its WiFi MAC address
    /// (remembered from an earlier reading).
    public static func read(_ listing: Listing) -> IOSDeviceStatus {
        var payload = cid_payload()
        // CITRUS_FORCE_IPV4=1 skips usbmuxd's address to exercise the fallback.
        let forceFallback = ProcessInfo.processInfo.environment["CITRUS_FORCE_IPV4"] != nil
        var status = forceFallback && listing.connection == .wifi
            ? CID_NOT_FOUND : cid_read(listing.udid, listing.connection == .wifi, &payload)
        defer { cid_free_payload(&payload) }

        if listing.connection == .wifi, status == CID_NOT_FOUND || status == CID_ERROR,
           let mac = KnownDevices.wifiAddress(for: listing.udid),
           let ipv4 = resolveIPv4(wifiAddress: mac) {
            cid_free_payload(&payload)
            status = cid_read_at(listing.udid, ipv4, &payload)
        }

        switch status {
        case CID_OK:
            guard let info = plist(payload.info, payload.info_length) else { return .unavailable }
            if let mac = info["WiFiAddress"] as? String {
                KnownDevices.remember(wifiAddress: mac, for: listing.udid)
            }
            return .ready(IOSDeviceSnapshot(
                udid: listing.udid, connection: listing.connection, info: info,
                battery: plist(payload.battery, payload.battery_length),
                pack: plist(payload.pack, payload.pack_length),
                gestalt: plist(payload.gestalt, payload.gestalt_length)))
        case CID_NOT_TRUSTED: return .notTrusted
        case CID_LOCKED: return .locked
        default: return .unavailable
        }
    }

    /// Browses briefly for WiFi-connectable devices. Besides finding nothing in
    /// particular, this makes macOS ask for Local Network access, which usbmuxd
    /// requires before it lists WiFi devices to an app.
    public static func requestLocalNetworkAccess() {
        var buffer = [CChar](repeating: 0, count: 64)
        _ = cid_resolve_ipv4("00:00:00:00:00:00", &buffer, Int32(buffer.count), 1500)
    }

    /// The device's current IPv4 address from its Bonjour announcement.
    public static func resolveIPv4(wifiAddress: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard cid_resolve_ipv4(wifiAddress.lowercased(), &buffer, Int32(buffer.count), 2000) else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The undecoded replies (lockdown info, IORegistry, MobileGestalt), for diagnostics.
    public static func readRaw(_ listing: Listing) -> (info: [String: Any]?, battery: [String: Any]?, pack: [String: Any]?, gestalt: [String: Any]?)? {
        var payload = cid_payload()
        let status = cid_read(listing.udid, listing.connection == .wifi, &payload)
        defer { cid_free_payload(&payload) }
        guard status == CID_OK else { return nil }
        return (plist(payload.info, payload.info_length), plist(payload.battery, payload.battery_length),
                plist(payload.pack, payload.pack_length), plist(payload.gestalt, payload.gestalt_length))
    }

    private static func plist(_ bytes: UnsafeMutablePointer<UInt8>?, _ length: UInt32) -> [String: Any]? {
        guard let bytes, length > 0 else { return nil }
        let data = Data(bytes: bytes, count: Int(length))
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// WiFi MAC addresses of devices read before, keyed by UDID, so a WiFi device
/// can be found on Bonjour when usbmuxd's address for it is stale.
public enum KnownDevices {
    private static let key = "knownDeviceWiFiAddresses"

    public static func wifiAddress(for udid: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[udid]
    }

    public static func remember(wifiAddress: String, for udid: String) {
        var known = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard known[udid] != wifiAddress else { return }
        known[udid] = wifiAddress
        UserDefaults.standard.set(known, forKey: key)
    }
}

/// Apple device names and icons by model identifier, from the device types macOS
/// declares (CoreTypes). These update with macOS, so new models are covered
/// without a hand-maintained table.
public enum DeviceModels {
    static var modelCodeTag: UTTagClass { UTTagClass(rawValue: "com.apple.device-model-code") }

    public static func type(for modelIdentifier: String) -> UTType? {
        UTType(tag: modelIdentifier, tagClass: modelCodeTag, conformingTo: nil)
    }

    /// e.g. "iPhone19,7" → "iPhone 18 Pro Max".
    public static func name(for modelIdentifier: String) -> String? {
        type(for: modelIdentifier)?.localizedDescription
    }
}
