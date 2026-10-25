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
    /// Brief wakes during those sleeps, with macOS's reasons, oldest first.
    @Published private(set) var darkWakes: [DarkWake] = []
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
    /// The last sleep, waiting for the gauge to refresh after waking.
    private var pendingMeasurement: (sleep: (date: Date, battery: MacBatterySnapshot), wokeAt: Date,
                                     task: Task<Void, Never>)?
    private var powerAggregator = PowerMinuteAggregator()
    /// Set while the system log is being read, so reads never overlap.
    private var readingSystemLog = false
    private var lastSystemLogCheck = Date.distantPast
    private var energyMeter = AppEnergyMeter()
    /// The last hour's readings. Saved totals are by the hour, so an hour from
    /// them could span nearly two; this keeps "the last hour" exact.
    private var recentAppUsage: [(date: Date, usage: [String: AppUsage], onBattery: Bool)] = []
    private var lastEnergyReading = Date.distantPast

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
        importWakeLog()
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
        let reading = MacBatteryReader.read()
        // A sleep still waiting for the gauge to refresh after the last wake ends
        // here: it takes this reading if the gauge has refreshed since that wake,
        // and otherwise goes unmeasured. Left waiting, it would take a reading
        // from after this sleep too and count this sleep's drain as its own.
        if let pending = pendingMeasurement {
            pending.task.cancel()
            pendingMeasurement = nil
            if let reading, (reading.gaugeUpdated ?? .distantPast) >= pending.wokeAt {
                finishMeasurement(sleep: pending.sleep, wokeAt: pending.wokeAt, after: reading)
            } else {
                let slept = Self.describe(pending.sleep.date, pending.wokeAt)
                Self.log.notice("Sleep \(slept, privacy: .public) not measured: slept again before the gauge refreshed")
            }
        }
        sleepReading = reading.map { (Date(), $0) }
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
        let task = Task { [weak self] in
            // The gauge refreshes about once a minute; allow for a slow first refresh.
            var after = MacBatteryReader.read()
            for _ in 0..<60 where after == nil || (after?.gaugeUpdated ?? wokeAt) < wokeAt {
                try? await Task.sleep(for: .seconds(5))
                // Cancelled when the Mac sleeps again first (see `willSleep`).
                if Task.isCancelled { return }
                after = MacBatteryReader.read()
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingMeasurement = nil
            guard let after, (after.gaugeUpdated ?? wokeAt) >= wokeAt else {
                let slept = Self.describe(sleep.date, wokeAt)
                Self.log.notice("Sleep \(slept, privacy: .public) not measured: no fresh reading after waking")
                return
            }
            self.finishMeasurement(sleep: sleep, wokeAt: wokeAt, after: after)
        }
        pendingMeasurement = (sleep, wokeAt, task)
    }

    /// Saves a sleep measured from the readings either side of it.
    private func finishMeasurement(sleep: (date: Date, battery: MacBatterySnapshot), wokeAt: Date,
                                   after: MacBatterySnapshot) {
        guard let store else { return }
        guard var session = SleepSession(before: sleep.battery, after: after,
                                         sleptAt: sleep.date, wokeAt: wokeAt) else {
            let detail = "power \(sleep.battery.isExternalPowerConnected)/\(after.isExternalPowerConnected), "
                + "capacity \(sleep.battery.currentCapacity ?? -1)→\(after.currentCapacity ?? -1)"
            let slept = Self.describe(sleep.date, wokeAt)
            Self.log.notice("Sleep \(slept, privacy: .public) not measured: \(detail, privacy: .public)")
            return
        }
        session.briefWakes = SleepDrain.briefWakes(during: session, minutes: powerMinutes)
        perform { try store.insert(session) }
        reloadSleepSessions()
        importWakeLog()
    }

    private static func describe(_ slept: Date, _ woke: Date) -> String {
        "\(slept.formatted(date: .omitted, time: .standard))–\(woke.formatted(date: .omitted, time: .standard))"
    }

    private func reloadSleepSessions() {
        perform {
            let wakes = try store?.darkWakes() ?? []
            darkWakes = wakes
            // Where macOS's log covered a sleep, its count beats the estimate from
            // power readings, which joins wakes in back-to-back minutes.
            sleepSessions = try (store?.sleepSessions() ?? []).map { session in
                guard session.wakesLogged else { return session }
                var counted = session
                counted.briefWakes = WakeBreakdown.wakes(wakes, during: [session]).count
                return counted
            }
        }
    }

    /// Saves the reasons for brief wakes during sleeps that macOS's power log
    /// still covers (about a week), since the log itself doesn't last. Sleeps
    /// whose wakes were saved before durations were read are read again.
    private func importWakeLog() {
        let logKept = Date().addingTimeInterval(-8 * 86_400)
        let pending = sleepSessions.filter { session in
            // Older sleeps are beyond the log, so reading it again can't help.
            guard session.end > logKept else { return false }
            guard session.wakesLogged else { return true }
            let wakes = WakeBreakdown.wakes(darkWakes, during: [session])
            return !wakes.isEmpty && wakes.allSatisfy { $0.seconds == nil }
        }
        guard !pending.isEmpty, let store else {
            importSystemLogIfDue()
            return
        }
        Task.detached(priority: .background) {
            guard let log = WakeLog.read() else { return }
            let (wakes, since) = WakeLog.parse(log)
            // Sessions the log covers from the start.
            guard let since else { return }
            let covered = pending.filter { since <= $0.start }
            guard !covered.isEmpty else { return }
            let inSleeps = WakeBreakdown.wakes(wakes, during: covered)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.perform { try store.insert(inSleeps, loggedSessions: covered.map(\.id)) }
                self.reloadSleepSessions()
                self.importSystemLogIfDue()
            }
        }
    }

    /// The system log is read for sleeps that ended this long ago at most; it
    /// usually keeps a few days, depending on how busy the Mac is.
    private static let systemLogReach: TimeInterval = 3 * 86_400
    /// Waiting after waking keeps the read clear of the work macOS does then.
    private static let systemLogDelay: TimeInterval = 3 * 60
    /// On battery the read waits for the charger until a sleep is this old.
    private static let systemLogBatteryGrace: TimeInterval = 12 * 3600

    /// Reads the system log for recent sleeps not yet read, one sleep at a time
    /// at background priority. On battery it waits for the charger, unless a
    /// sleep would otherwise soon fall out of the log.
    private func importSystemLogIfDue() {
        guard !readingSystemLog, let store else { return }
        let now = Date()
        let pending = sleepSessions.filter { session in
            session.wakesLogged && !session.appsLogged
                && now.timeIntervalSince(session.end) < Self.systemLogReach
                && now.timeIntervalSince(session.end) > Self.systemLogDelay
                && !WakeBreakdown.wakes(darkWakes, during: [session]).isEmpty
        }
        guard let oldest = pending.map(\.end).min() else { return }
        let charging = monitor?.battery?.isExternalPowerConnected ?? false
        guard charging || now.timeIntervalSince(oldest) > Self.systemLogBatteryGrace else { return }
        readingSystemLog = true
        let wakes = darkWakes
        Task.detached(priority: .background) {
            for session in pending {
                let during = WakeBreakdown.wakes(wakes, during: [session])
                guard let first = during.first, let last = during.last else { continue }
                // Only the span from the first wake to the end of the last, so
                // `log` searches as little as possible. A read that fails or
                // times out isn't retried, so it can't repeat its cost.
                let text = SystemLog.read(from: first.date.addingTimeInterval(-5),
                                          to: last.date.addingTimeInterval(TimeInterval((last.seconds ?? 0) + 10)))
                let annotated = text.map { SystemLog.annotate(during, with: SystemLog.parse($0)) } ?? []
                await MainActor.run { [weak self] in
                    self?.perform { try store.annotate(annotated, loggedSessions: [session.id], failed: text == nil) }
                }
            }
            await MainActor.run { [weak self] in
                self?.readingSystemLog = false
                self?.reloadSleepSessions()
            }
        }
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
        // Readings arrive every few seconds; checking whether the system log is
        // due is cheap, but there's no need to do it more than every 10 minutes.
        if Date().timeIntervalSince(lastSystemLogCheck) > 600 {
            lastSystemLogCheck = Date()
            importSystemLogIfDue()
        }
        if Date().timeIntervalSince(lastEnergyReading) >= 60 {
            lastEnergyReading = Date()
            recordAppEnergy()
        }
        guard let watts = power.systemWatts else { return }
        let battery = monitor?.battery
        let charge = battery?.powerSource?.chargePercent
            ?? battery?.rawChargeFraction.map { Int(($0 * 100).rounded()) }
        if let minute = powerAggregator.add(watts: watts, at: Date(), chargePercent: charge,
                                            onAdapter: battery?.isExternalPowerConnected ?? true) {
            savePowerMinute(minute)
        }
    }

    /// Adds each app's energy since the last reading to its hourly total. Reading
    /// every process takes a few milliseconds, once a minute.
    private func recordAppEnergy() {
        let usage = energyMeter.measure().filter { $0.value.joules >= 0.01 || $0.value.cpuSeconds >= 0.01 }
        let onBattery = !(monitor?.battery?.isExternalPowerConnected ?? true)
        let now = Date()
        perform { try store?.addAppUsage(usage, at: now, onBattery: onBattery) }
        recentAppUsage.append((now, usage, onBattery))
        recentAppUsage.removeAll { now.timeIntervalSince($0.date) > 3600 }
    }

    /// Each app's energy since `date`, most first, and when recording began.
    /// Up to an hour comes from the readings in memory, exactly; longer from the
    /// saved hourly totals, from the start of the hour containing `date`.
    func appEnergy(since date: Date, onBatteryOnly: Bool) -> (apps: [(app: String, usage: AppUsage)], since: Date?) {
        if Date().timeIntervalSince(date) <= 3600 {
            var totals: [String: AppUsage] = [:]
            let readings = recentAppUsage.filter { $0.date > date && (!onBatteryOnly || $0.onBattery) }
            for reading in readings {
                for (app, usage) in reading.usage { totals[app, default: AppUsage()] = totals[app, default: AppUsage()] + usage }
            }
            // Each reading covers the minute before it.
            let since = recentAppUsage.first.map { $0.date.addingTimeInterval(-60) }
            return (totals.map { (app: $0.key, usage: $0.value) }, since)
        }
        var result: (apps: [(app: String, usage: AppUsage)], since: Date?) = ([], nil)
        perform {
            let rows = try store?.appUsage(since: date) ?? []
            result.apps = rows.map { (app: $0.app, usage: onBatteryOnly ? $0.onBattery : $0.total) }
            result.since = try store?.appUsageStart()
        }
        return result
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

    @discardableResult
    func importBackup(_ data: Data) -> HistoryStore.BackupImport {
        var added = HistoryStore.BackupImport(entries: 0, sleepSessions: 0)
        perform { added = try store?.importBackup(data) ?? added }
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
