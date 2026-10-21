import CitrusKit
import Combine
import Foundation

/// Owns the history database: SmartSave, manual saves, and the viewer's data.
@MainActor
final class HistoryController: ObservableObject {
    @Published private(set) var devices: [HistoryDevice] = []
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var selectedDeviceSerial: String? {
        didSet { reloadEntries() }
    }
    @Published private(set) var lastError: String?

    private let store: HistoryStore?
    private weak var monitor: BatteryMonitor?
    private weak var iosDevices: IOSDeviceMonitor?
    private var observers: [AnyCancellable] = []
    /// Last SmartSave attempt per device serial.
    private var lastAutosaveAttempt: [String: Date] = [:]
    private let launchDate = Date()

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
            .sink { [weak self] battery in self?.considerAutosave(mac: battery) })
        observers.append(iosDevices.$devices
            .sink { [weak self] devices in
                for device in devices where device.state == .ready {
                    self?.considerAutosave(device: device)
                }
            })
    }

    var autosaveNewDevices: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.autosaveNewDevices) as? Bool ?? true
    }

    /// This Mac's history key (its serial number).
    var thisMacSerial: String? {
        guard let monitor else { return nil }
        return monitor.macInfo.serialNumber ?? monitor.macInfo.modelIdentifier
    }

    // MARK: Saving

    private func considerAutosave(mac battery: MacBatterySnapshot) {
        guard let monitor else { return }
        // Give the marketing name a moment to load so the first entry is labelled well.
        if monitor.marketingName == nil, Date().timeIntervalSince(launchDate) < 30 { return }
        considerAutosave(macEntry(battery))
    }

    private func considerAutosave(device: TrackedDevice) {
        guard let snapshot = device.snapshot, let battery = snapshot.battery else { return }
        considerAutosave(HistoryEntry(device: snapshot, battery: battery))
    }

    /// SmartSave: at most one attempt an hour per device, skipping same-day duplicates.
    private func considerAutosave(_ entry: HistoryEntry) {
        guard let store else { return }
        let serial = entry.deviceSerial
        if let last = lastAutosaveAttempt[serial], Date().timeIntervalSince(last) < SmartSavePolicy.minimumInterval {
            return
        }
        lastAutosaveAttempt[serial] = Date()

        let enabled = (try? store.smartSave(deviceSerial: serial)) ?? nil ?? autosaveNewDevices
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
               SmartSavePolicy.isDuplicate(entry, of: try store.entries(deviceSerial: entry.deviceSerial)) {
                return
            }
            try store.insert(entry)
        }
        if selectedDeviceSerial == nil { selectedDeviceSerial = entry.deviceSerial }
        reload()
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

    func setSmartSave(_ enabled: Bool, for serial: String) {
        perform { try store?.setSmartSave(enabled, deviceSerial: serial) }
        reload()
    }

    /// SmartSave state for a device, falling back to the default for new devices.
    func smartSave(for serial: String) -> Bool {
        ((try? store?.smartSave(deviceSerial: serial)) ?? nil) ?? autosaveNewDevices
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

    /// Imports a coconutBattery `.ccba` backup. Returns the number of entries added.
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
        perform { devices = try store.devices(defaultSmartSave: autosaveNewDevices) }
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
