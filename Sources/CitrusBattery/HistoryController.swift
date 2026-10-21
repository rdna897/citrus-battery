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
    private var readingObserver: AnyCancellable?
    private var lastAutosaveAttempt: Date?
    private let launchDate = Date()

    init(monitor: BatteryMonitor, store: HistoryStore? = nil) {
        self.monitor = monitor
        do {
            self.store = try store ?? HistoryStore()
        } catch {
            self.store = nil
            lastError = error.localizedDescription
        }
        reload()
        readingObserver = monitor.$battery
            .compactMap { $0 }
            .sink { [weak self] battery in self?.considerAutosave(battery) }
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

    /// SmartSave: at most one attempt an hour, skipping same-day duplicates.
    private func considerAutosave(_ battery: MacBatterySnapshot) {
        guard let store, let monitor, let serial = thisMacSerial else { return }
        // Give the marketing name a moment to load so the first entry is labelled well.
        if monitor.marketingName == nil, Date().timeIntervalSince(launchDate) < 30 { return }
        if let last = lastAutosaveAttempt, Date().timeIntervalSince(last) < SmartSavePolicy.minimumInterval { return }
        lastAutosaveAttempt = Date()

        let enabled = (try? store.smartSave(deviceSerial: serial)) ?? nil ?? autosaveNewDevices
        guard enabled else { return }
        save(battery, skippingDuplicates: true)
    }

    /// Saves the current reading now (the "Save Now" button), even if a similar one exists.
    func saveNow() {
        guard let battery = monitor?.battery else { return }
        save(battery, skippingDuplicates: false)
    }

    private func save(_ battery: MacBatterySnapshot, skippingDuplicates: Bool) {
        guard let store, let monitor else { return }
        let name = monitor.marketingName ?? monitor.macInfo.modelIdentifier
        let entry = HistoryEntry(mac: monitor.macInfo, name: name, battery: battery)
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
