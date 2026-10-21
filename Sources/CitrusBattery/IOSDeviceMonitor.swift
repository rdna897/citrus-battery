import CitrusKit
import Foundation

/// An iPhone or iPad seen during this session, with its latest status.
struct TrackedDevice: Identifiable, Equatable {
    enum State: Equatable {
        case ready
        case notTrusted
        case locked
        case unavailable
        /// No longer connected; `snapshot` holds the last reading.
        case disconnected
    }

    var udid: String
    var state: State
    var connection: IOSDeviceSnapshot.Connection?
    /// The last successful reading.
    var snapshot: IOSDeviceSnapshot?
    var lastSeen: Date?

    var id: String { udid }

    var displayName: String { snapshot?.name ?? "iPhone or iPad" }
    var deviceClass: String { snapshot?.deviceClass ?? "iPhone" }
    var symbolName: String {
        switch deviceClass {
        case "iPad": "ipad"
        case "Apple Watch": "applewatch"
        default: "iphone"
        }
    }
}

/// Polls connected iPhones and iPads in the background.
@MainActor
final class IOSDeviceMonitor: ObservableObject {
    @Published private(set) var devices: [TrackedDevice] = []
    @Published private(set) var isRefreshing = false

    /// Devices not heard from for an hour are hidden.
    static let staleInterval: TimeInterval = 3600
    private static let pollInterval: TimeInterval = 30

    private var timer: Timer?

    init() {
        Task.detached(priority: .utility) { IOSDeviceReader.requestLocalNetworkAccess() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    #if DEBUG
    /// Documentation data without discovery, polling or network access.
    init(sampleDevices: [TrackedDevice]) {
        devices = sampleDevices
    }
    #endif

    func device(udid: String) -> TrackedDevice? {
        devices.first { $0.udid == udid }
    }

    /// Re-reads every connected device. Overlapping refreshes are skipped.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) {
            let listings = IOSDeviceReader.connectedDevices()
            var results: [(IOSDeviceReader.Listing, IOSDeviceStatus)] = []
            let debug = ProcessInfo.processInfo.environment["CITRUS_DEBUG_DEVICES"] != nil
            for listing in listings {
                let status = IOSDeviceReader.read(listing)
                if debug {
                    FileHandle.standardError.write(Data("device \(listing.udid) \(listing.connection) → \(status)\n".utf8))
                }
                results.append((listing, status))
            }
            if debug, listings.isEmpty {
                FileHandle.standardError.write(Data("no devices listed\n".utf8))
            }
            await MainActor.run { [weak self] in self?.apply(results) }
        }
    }

    private func apply(_ results: [(IOSDeviceReader.Listing, IOSDeviceStatus)]) {
        let now = Date()
        var updated = devices
        let present = Set(results.map(\.0.udid))

        for (listing, status) in results {
            var device = updated.first { $0.udid == listing.udid }
                ?? TrackedDevice(udid: listing.udid, state: .unavailable)
            device.connection = listing.connection
            switch status {
            case let .ready(snapshot):
                device.state = .ready
                device.snapshot = snapshot
                device.lastSeen = now
            case .notTrusted:
                device.state = .notTrusted
            case .locked:
                device.state = .locked
            case .unavailable:
                device.state = .unavailable
            }
            if let index = updated.firstIndex(where: { $0.udid == device.udid }) {
                updated[index] = device
            } else {
                updated.append(device)
            }
        }

        for index in updated.indices where !present.contains(updated[index].udid) {
            updated[index].state = .disconnected
        }
        // Forget devices that disconnected without ever being read, or long ago.
        updated.removeAll { device in
            device.state == .disconnected
                && (device.lastSeen.map { now.timeIntervalSince($0) > Self.staleInterval } ?? true)
        }

        devices = updated
        isRefreshing = false
    }
}
