import AppKit
import CitrusKit
import Combine
import Foundation
import os

/// Owns the history database: Auto-Record, manual saves, and the viewer's data.
@MainActor
final class HistoryController: ObservableObject {
    private static let log = Logger(subsystem: "org.citrusbattery.CitrusBattery", category: "History")

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
    /// The last 30 days of power readings and sleeps, for the power chart.
    @Published private(set) var powerMinutes: [PowerMinute] = []
    @Published private(set) var sleepPeriods: [DateInterval] = []

    private let store: HistoryStore?
    private weak var monitor: BatteryMonitor?
    private weak var iosDevices: IOSDeviceMonitor?
    private var observers: [AnyCancellable] = []
    /// Last Auto-Record attempt per device serial.
    private var lastAutoRecordAttempt: [String: Date] = [:]
    private let launchDate = Date()
    /// The reading taken as the Mac went to sleep.
    private var sleepReading: (date: Date, battery: MacBatterySnapshot)?
    private var sleepStarted: Date?
    private var powerAggregator = PowerMinuteAggregator()

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
        // `$power` publishes after `battery` has been updated for the same reading.
        observers.append(monitor.$power
            .sink { [weak self] power in self?.recordPower(power) })
        loadPowerTimeline()
        fillBriefWakes()
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
        sleepStarted = Date()
        sleepReading = MacBatteryReader.read().map { (Date(), $0) }
        if let minute = powerAggregator.flush() { savePowerMinute(minute) }
    }

    /// Measures the sleep once the gauge has refreshed after waking (about once a
    /// minute); until then it still reports the values from before sleep.
    private func didWake() {
        if let start = sleepStarted, Date().timeIntervalSince(start) >= 60 {
            let period = DateInterval(start: start, end: Date())
            perform { try store?.insertSleepPeriod(period) }
            sleepPeriods.append(period)
        }
        sleepStarted = nil
        guard let sleep = sleepReading else { return }
        sleepReading = nil
        let wokeAt = Date()
        guard wokeAt.timeIntervalSince(sleep.date) >= SleepSession.minimumDuration else { return }
        Task { [weak self] in
            // The gauge refreshes about once a minute; allow for a slow first refresh.
            var after = MacBatteryReader.read()
            for _ in 0..<60 where after == nil || (after?.gaugeUpdated ?? wokeAt) < wokeAt {
                try? await Task.sleep(for: .seconds(5))
                after = MacBatteryReader.read()
            }
            let slept = "\(sleep.date.formatted(date: .omitted, time: .standard))–"
                + wokeAt.formatted(date: .omitted, time: .standard)
            guard let after, (after.gaugeUpdated ?? wokeAt) >= wokeAt else {
                Self.log.notice("Sleep \(slept, privacy: .public) not measured: no fresh reading after waking")
                return
            }
            guard let self, let store = self.store else { return }
            guard var session = SleepSession(before: sleep.battery, after: after,
                                             sleptAt: sleep.date, wokeAt: wokeAt) else {
                let detail = "power \(sleep.battery.isExternalPowerConnected)/\(after.isExternalPowerConnected), "
                    + "capacity \(sleep.battery.currentCapacity ?? -1)→\(after.currentCapacity ?? -1)"
                Self.log.notice("Sleep \(slept, privacy: .public) not measured: \(detail, privacy: .public)")
                return
            }
            session.briefWakes = SleepDrain.briefWakes(during: session, minutes: self.powerMinutes)
            self.perform { try store.insert(session) }
            self.reloadSleepSessions()
        }
    }

    private func reloadSleepSessions() {
        perform { sleepSessions = try store?.sleepSessions() ?? [] }
    }

    /// Counts brief wakes for sessions saved without them while the power readings
    /// still cover them (they're kept for 30 days), so the count outlives them.
    private func fillBriefWakes() {
        var filled = false
        for session in sleepSessions where session.briefWakes == nil {
            guard let count = SleepDrain.briefWakes(during: session, minutes: powerMinutes) else { continue }
            perform { try store?.setBriefWakes(count, forSleepSession: session.id) }
            filled = true
        }
        if filled { reloadSleepSessions() }
    }

    // MARK: Power timeline

    private func recordPower(_ power: PowerReadings) {
        guard let watts = power.systemWatts else { return }
        let battery = monitor?.battery
        let charge = battery?.powerSource?.chargePercent
            ?? battery?.rawChargeFraction.map { Int(($0 * 100).rounded()) }
        if let minute = powerAggregator.add(watts: watts, at: Date(), chargePercent: charge,
                                            onAdapter: battery?.isExternalPowerConnected ?? true) {
            savePowerMinute(minute)
        }
    }

    private func savePowerMinute(_ minute: PowerMinute) {
        perform { try store?.insert(minute) }
        powerMinutes.append(minute)
        let cutoff = Date().addingTimeInterval(-PowerTimeline.retention)
        if let first = powerMinutes.first, first.start < cutoff {
            powerMinutes.removeAll { $0.start < cutoff }
            sleepPeriods.removeAll { $0.end < cutoff }
        }
    }

    private func loadPowerTimeline() {
        let since = Date().addingTimeInterval(-PowerTimeline.retention)
        perform {
            powerMinutes = try store?.powerMinutes(since: since) ?? []
            sleepPeriods = try store?.sleepPeriods(since: since) ?? []
        }
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
