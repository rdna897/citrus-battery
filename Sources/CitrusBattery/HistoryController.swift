import AppKit
import CitrusKit
import Combine
import Foundation

/// Owns the history database: Auto-Record, manual saves, and the viewer's data.
@MainActor
final class HistoryController: ObservableObject {
    @Published private(set) var devices: [HistoryDevice] = []
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var selectedDeviceSerial: String? {
        didSet { reloadEntries() }
    }
    @Published private(set) var lastError: String?
    /// Health trend per device serial.
    @Published private(set) var trends: [String: HealthTrend] = [:]
    /// This Mac's sleeps on battery, newest first.
    @Published private(set) var sleepSessions: [SleepSession] = []

    private let store: HistoryStore?
    private weak var monitor: BatteryMonitor?
    private weak var iosDevices: IOSDeviceMonitor?
    private var observers: [AnyCancellable] = []
    /// Last Auto-Record attempt per device serial.
    private var lastAutoRecordAttempt: [String: Date] = [:]
    private let launchDate = Date()
    /// The reading taken as the Mac went to sleep.
    private var sleepReading: (date: Date, battery: MacBatterySnapshot)?

    init(monitor: BatteryMonitor, iosDevices: IOSDeviceMonitor, store: HistoryStore? = nil) {
        self.monitor = monitor
        self.iosDevices = iosDevices
        do {
            self.store = try store ?? HistoryStore()
        } catch {
            self.store = nil
            lastError = error.localizedDescription
        }
        reload()
        observers.append(monitor.$battery
            .compactMap { $0 }
            .sink { [weak self] battery in self?.considerAutoRecord(mac: battery) })
        observers.append(iosDevices.$devices
            .sink { [weak self] devices in
                for device in devices where device.state == .ready {
                    self?.considerAutoRecord(device: device)
                }
            })
        // Posted on the main thread; handled synchronously so the reading is
        // taken before the Mac actually sleeps.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.willSleep() } })
        observers.append(workspace.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.didWake() } })
    }

    var autoRecordNewDevices: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.autosaveNewDevices) as? Bool ?? true
    }

    /// This Mac's history key (its serial number).
    var thisMacSerial: String? {
        guard let monitor else { return nil }
        return monitor.macInfo.serialNumber ?? monitor.macInfo.modelIdentifier
    }

    // MARK: Saving

    private func considerAutoRecord(mac battery: MacBatterySnapshot) {
        guard let monitor else { return }
        // Give the marketing name a moment to load so the first entry is labelled well.
        if monitor.marketingName == nil, Date().timeIntervalSince(launchDate) < 30 { return }
        considerAutoRecord(macEntry(battery))
    }

    private func considerAutoRecord(device: TrackedDevice) {
        guard let snapshot = device.snapshot, let battery = snapshot.battery else { return }
        considerAutoRecord(HistoryEntry(device: snapshot, battery: battery))
    }

    /// Auto-Record: at most one attempt an hour per device, skipping same-day duplicates.
    private func considerAutoRecord(_ entry: HistoryEntry) {
        guard let store else { return }
        let serial = entry.deviceSerial
        if let last = lastAutoRecordAttempt[serial], Date().timeIntervalSince(last) < AutoRecordPolicy.minimumInterval {
            return
        }
        lastAutoRecordAttempt[serial] = Date()

        let enabled = (try? store.autoRecord(deviceSerial: serial)) ?? nil ?? autoRecordNewDevices
        guard enabled else { return }
        save(entry, skippingDuplicates: true)
    }

    /// Saves the selected device's current reading now (the "Save Now" button), even
    /// if a similar one exists. Falls back to this Mac when the selected device isn't
    /// connected.
    func saveNow() {
        if let serial = selectedDeviceSerial,
           let device = iosDevices?.devices.first(where: { $0.snapshot?.serialNumber == serial || $0.udid == serial }),
           device.state == .ready, let snapshot = device.snapshot, let battery = snapshot.battery {
            save(HistoryEntry(device: snapshot, battery: battery), skippingDuplicates: false)
            return
        }
        guard let battery = monitor?.battery else { return }
        save(macEntry(battery), skippingDuplicates: false)
    }

    private func macEntry(_ battery: MacBatterySnapshot) -> HistoryEntry {
        let name = monitor?.marketingName ?? monitor?.macInfo.modelIdentifier ?? "Mac"
        return HistoryEntry(mac: monitor?.macInfo ?? MacInfo.read(), name: name, battery: battery)
    }

    private func save(_ entry: HistoryEntry, skippingDuplicates: Bool) {
        guard let store else { return }
        perform {
            if skippingDuplicates,
               AutoRecordPolicy.isDuplicate(entry, of: try store.entries(deviceSerial: entry.deviceSerial)) {
                return
            }
            try store.insert(entry)
        }
        if selectedDeviceSerial == nil { selectedDeviceSerial = entry.deviceSerial }
        reload()
    }

    // MARK: Sleep

    private func willSleep() {
        sleepReading = MacBatteryReader.read().map { (Date(), $0) }
    }

    /// Measures the sleep once the gauge has refreshed after waking (about once a
    /// minute); until then it still reports the values from before sleep.
    private func didWake() {
        guard let sleep = sleepReading else { return }
        sleepReading = nil
        let wokeAt = Date()
        Task { [weak self] in
            var after = MacBatteryReader.read()
            for _ in 0..<24 where (after?.gaugeUpdated ?? wokeAt) < wokeAt {
                try? await Task.sleep(for: .seconds(5))
                after = MacBatteryReader.read()
            }
            guard let self, let store = self.store, let after, (after.gaugeUpdated ?? wokeAt) >= wokeAt,
                  let session = SleepSession(before: sleep.battery, after: after,
                                             sleptAt: sleep.date, wokeAt: wokeAt)
            else { return }
            self.perform { try store.insert(session) }
            self.reloadSleepSessions()
        }
    }

    private func reloadSleepSessions() {
        perform { sleepSessions = try store?.sleepSessions() ?? [] }
    }

    // MARK: Editing

    func delete(ids: Set<Int64>) {
        perform { try store?.delete(ids: ids) }
        reload()
    }

    func deleteAllForSelectedDevice() {
        guard let serial = selectedDeviceSerial else { return }
        perform { try store?.deleteAll(deviceSerial: serial) }
        selectedDeviceSerial = nil
        reload()
    }

    func setAutoRecord(_ enabled: Bool, for serial: String) {
        perform { try store?.setAutoRecord(enabled, deviceSerial: serial) }
        reload()
    }

    /// Auto-Record state for a device, falling back to the default for new devices.
    func autoRecord(for serial: String) -> Bool {
        ((try? store?.autoRecord(deviceSerial: serial)) ?? nil) ?? autoRecordNewDevices
    }

    // MARK: Backup

    func exportBackup() -> Data? {
        var data: Data?
        perform { data = try store?.exportBackup() }
        return data
    }

    /// Returns the number of entries added.
    @discardableResult
    func importBackup(_ data: Data) -> Int {
        var added = 0
        perform { added = try store?.importBackup(data) ?? 0 }
        reload()
        return added
    }

    /// Imports a `.ccba` backup. Returns the number of entries added.
    func importCoconutBatteryBackup(_ data: Data) -> Int {
        var added = 0
        perform {
            let entries = try CoconutBatteryBackup.entries(from: data)
            added = try store?.importEntries(entries) ?? 0
        }
        reload()
        return added
    }

    func reportError(_ message: String) {
        lastError = message
    }

    func clearError() {
        lastError = nil
    }

    // MARK: Loading

    func reload() {
        guard let store else { return }
        reloadSleepSessions()
        perform { devices = try store.devices(defaultAutoRecord: autoRecordNewDevices) }
        perform {
            var trends: [String: HealthTrend] = [:]
            for device in devices {
                trends[device.serial] = HealthForecast.trend(entries: try store.entries(deviceSerial: device.serial))
            }
            self.trends = trends
        }
        if selectedDeviceSerial == nil || !devices.contains(where: { $0.serial == selectedDeviceSerial }) {
            selectedDeviceSerial = devices.first(where: { $0.serial == thisMacSerial })?.serial ?? devices.first?.serial
        } else {
            reloadEntries()
        }
    }

    private func reloadEntries() {
        guard let store, let serial = selectedDeviceSerial else {
            entries = []
            return
        }
        perform { entries = try store.entries(deviceSerial: serial) }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
