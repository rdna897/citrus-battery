import Foundation
import SQLite3

/// One saved battery reading.
public struct HistoryEntry: Identifiable, Sendable, Equatable, Codable {
    public enum DeviceType: String, Sendable, Codable {
        case mac, iOS
    }

    public var id: Int64
    public var date: Date
    public var deviceType: DeviceType
    public var deviceSerial: String
    public var deviceName: String
    public var deviceModel: String
    public var osVersion: String?
    public var batterySerial: String?
    public var cycleCount: Int?
    public var designCapacity: Int?
    public var fullChargeCapacity: Int?
    /// Format version of this entry, for future migrations.
    public var dataVersion: Int
    public var comment: String?

    public init(id: Int64 = 0, date: Date, deviceType: DeviceType, deviceSerial: String,
                deviceName: String, deviceModel: String, osVersion: String? = nil,
                batterySerial: String? = nil, cycleCount: Int? = nil, designCapacity: Int? = nil,
                fullChargeCapacity: Int? = nil, dataVersion: Int = HistoryEntry.currentDataVersion,
                comment: String? = nil) {
        self.id = id
        self.date = date
        self.deviceType = deviceType
        self.deviceSerial = deviceSerial
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.batterySerial = batterySerial
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.dataVersion = dataVersion
        self.comment = comment
    }

    public static let currentDataVersion = 1

    /// Full-charge ÷ design capacity.
    public var healthFraction: Double? {
        guard let fullChargeCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Double(fullChargeCapacity) / Double(designCapacity)
    }
}

/// A device that has history, with its Auto-Record setting.
public struct HistoryDevice: Identifiable, Sendable, Equatable {
    public var serial: String
    public var name: String
    public var model: String
    public var type: HistoryEntry.DeviceType
    public var entryCount: Int
    public var lastSaved: Date?
    public var autoRecord: Bool

    public var id: String { serial }
}

public enum HistoryError: Error, LocalizedError, Equatable {
    case database(String)
    case unreadableBackup
    case damagedBackup

    public var errorDescription: String? {
        switch self {
        case let .database(message): "History database error: \(message)"
        case .unreadableBackup: "This file isn't a Citrus Battery history backup."
        case .damagedBackup: "This backup has damaged sleep records, so nothing was imported."
        }
    }
}

/// When Auto-Record should record a new entry.
public enum AutoRecordPolicy {
    /// Minimum time between automatic save attempts.
    public static let minimumInterval: TimeInterval = 3600
    /// Capacity tolerance for treating a reading as a duplicate.
    public static let capacityTolerance = 0.05

    /// A reading duplicates an existing entry if one from the same calendar day
    /// has the same cycle count and a full-charge capacity within ±5%.
    public static func isDuplicate(_ candidate: HistoryEntry, of existing: [HistoryEntry],
                                   calendar: Calendar = .current) -> Bool {
        existing.contains { entry in
            guard calendar.isDate(entry.date, inSameDayAs: candidate.date),
                  entry.cycleCount == candidate.cycleCount
            else { return false }
            guard let old = entry.fullChargeCapacity, let new = candidate.fullChargeCapacity else {
                return entry.fullChargeCapacity == candidate.fullChargeCapacity
            }
            let low = Double(old) * (1 - capacityTolerance)
            let high = Double(old) * (1 + capacityTolerance)
            return (low...high).contains(Double(new))
        }
    }
}

/// SQLite-backed battery history.
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// `~/Library/Application Support/Citrus Battery/history.sqlite`.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Citrus Battery", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    /// Opens (creating if needed) the database at `url`; pass `nil` for an in-memory store.
    public init(url: URL? = HistoryStore.defaultURL) throws {
        let path: String
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            path = url.path
        } else {
            path = ":memory:"
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw HistoryError.database(message)
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date REAL NOT NULL,
                device_type TEXT NOT NULL,
                device_serial TEXT NOT NULL,
                device_name TEXT NOT NULL,
                device_model TEXT NOT NULL,
                os_version TEXT,
                battery_serial TEXT,
                cycle_count INTEGER,
                design_capacity INTEGER,
                full_charge_capacity INTEGER,
                data_version INTEGER NOT NULL,
                comment TEXT
            );
            CREATE INDEX IF NOT EXISTS entries_device_date ON entries (device_serial, date);
            CREATE TABLE IF NOT EXISTS devices (
                serial TEXT PRIMARY KEY,
                auto_record INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sleep_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start REAL NOT NULL,
                end REAL NOT NULL,
                start_capacity INTEGER NOT NULL,
                end_capacity INTEGER NOT NULL,
                full_charge_capacity INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS power_minutes (
                start REAL PRIMARY KEY,
                average_watts REAL NOT NULL,
                peak_watts REAL NOT NULL,
                charge_percent INTEGER,
                on_adapter INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sleep_periods (
                start REAL PRIMARY KEY,
                end REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS app_energy (
                hour REAL NOT NULL,
                app TEXT NOT NULL,
                joules REAL NOT NULL,
                battery_joules REAL NOT NULL,
                cpu_seconds REAL NOT NULL,
                PRIMARY KEY (hour, app)
            );
            CREATE TABLE IF NOT EXISTS dark_wakes (
                date REAL PRIMARY KEY,
                reason TEXT NOT NULL,
                detail TEXT
            );
            """)
        try renameLegacyColumn()
        try addColumnIfMissing(table: "sleep_sessions", column: "brief_wakes", type: "INTEGER")
        try addColumnIfMissing(table: "sleep_sessions", column: "wakes_logged", type: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "sleep_sessions", column: "apps_logged", type: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "dark_wakes", column: "seconds", type: "INTEGER")
        try addColumnIfMissing(table: "dark_wakes", column: "holders", type: "TEXT")
        try addColumnIfMissing(table: "dark_wakes", column: "apps", type: "TEXT")
    }

    private func addColumnIfMissing(table: String, column: String, type: String) throws {
        let statement = try prepare("SELECT 1 FROM pragma_table_info('\(table)') WHERE name = '\(column)'")
        let exists = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        if !exists {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
    }

    /// Databases from earlier builds named the per-device column `smart_save`.
    private func renameLegacyColumn() throws {
        let statement = try prepare("SELECT 1 FROM pragma_table_info('devices') WHERE name = 'smart_save'")
        let hasLegacy = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        if hasLegacy {
            try execute("ALTER TABLE devices RENAME COLUMN smart_save TO auto_record")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Entries

    @discardableResult
    public func insert(_ entry: HistoryEntry) throws -> Int64 {
        try locked {
            let statement = try prepare("""
                INSERT INTO entries (date, device_type, device_serial, device_name, device_model, os_version,
                    battery_serial, cycle_count, design_capacity, full_charge_capacity, data_version, comment)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, entry.date.timeIntervalSince1970)
            bind(statement, 2, entry.deviceType.rawValue)
            bind(statement, 3, entry.deviceSerial)
            bind(statement, 4, entry.deviceName)
            bind(statement, 5, entry.deviceModel)
            bind(statement, 6, entry.osVersion)
            bind(statement, 7, entry.batterySerial)
            bind(statement, 8, entry.cycleCount)
            bind(statement, 9, entry.designCapacity)
            bind(statement, 10, entry.fullChargeCapacity)
            bind(statement, 11, entry.dataVersion)
            bind(statement, 12, entry.comment)
            try step(statement)
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Entries for one device, newest first; all devices when `deviceSerial` is nil.
    public func entries(deviceSerial: String? = nil) throws -> [HistoryEntry] {
        try locked {
            let sql = "SELECT id, date, device_type, device_serial, device_name, device_model, os_version, "
                + "battery_serial, cycle_count, design_capacity, full_charge_capacity, data_version, comment "
                + "FROM entries" + (deviceSerial == nil ? "" : " WHERE device_serial = ?") + " ORDER BY date DESC"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let deviceSerial { bind(statement, 1, deviceSerial) }

            var result: [HistoryEntry] = []
            try forEachRow(statement) {
                result.append(HistoryEntry(
                    id: sqlite3_column_int64(statement, 0),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    deviceType: HistoryEntry.DeviceType(rawValue: text(statement, 2) ?? "") ?? .mac,
                    deviceSerial: text(statement, 3) ?? "",
                    deviceName: text(statement, 4) ?? "",
                    deviceModel: text(statement, 5) ?? "",
                    osVersion: text(statement, 6),
                    batterySerial: text(statement, 7),
                    cycleCount: int(statement, 8),
                    designCapacity: int(statement, 9),
                    fullChargeCapacity: int(statement, 10),
                    dataVersion: int(statement, 11) ?? 1,
                    comment: text(statement, 12)
                ))
            }
            return result
        }
    }

    public func delete(ids: Set<Int64>) throws {
        guard !ids.isEmpty else { return }
        try locked {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let statement = try prepare("DELETE FROM entries WHERE id IN (\(placeholders))")
            defer { sqlite3_finalize(statement) }
            for (index, id) in ids.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), id)
            }
            try step(statement)
        }
    }

    public func deleteAll(deviceSerial: String) throws {
        try locked {
            let statement = try prepare("DELETE FROM entries WHERE device_serial = ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, deviceSerial)
            try step(statement)
        }
    }

    // MARK: Sleep

    /// Sessions are kept indefinitely: a row is a few dozen bytes, so years of
    /// nightly sleeps stay well under a megabyte.
    public func insert(_ session: SleepSession) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO sleep_sessions (start, end, start_capacity, end_capacity, full_charge_capacity,
                    brief_wakes, wakes_logged, apps_logged)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, session.start.timeIntervalSince1970)
            bind(statement, 2, session.end.timeIntervalSince1970)
            bind(statement, 3, session.startCapacity)
            bind(statement, 4, session.endCapacity)
            bind(statement, 5, session.fullChargeCapacity)
            bind(statement, 6, session.briefWakes)
            bind(statement, 7, session.wakesLogged ? 1 : 0)
            bind(statement, 8, session.appsReadFailed ? Self.appsReadFailed : session.appsLogged ? 1 : 0)
            try step(statement)
        }
    }

    /// Saves brief wakes read from macOS's power log and marks the sessions they
    /// were read for. A wake already saved takes the power log's duration and
    /// holders, and keeps its reason and apps, which the system log may have refined.
    public func insert(_ wakes: [DarkWake], loggedSessions: [Int64]) throws {
        try locked {
            try execute("BEGIN")
            do {
                let insert = try prepare("""
                    INSERT INTO dark_wakes (date, reason, detail, seconds, holders, apps) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(date) DO UPDATE SET
                        seconds = COALESCE(excluded.seconds, dark_wakes.seconds),
                        holders = COALESCE(excluded.holders, dark_wakes.holders),
                        apps = COALESCE(dark_wakes.apps, excluded.apps)
                    """)
                defer { sqlite3_finalize(insert) }
                for wake in wakes {
                    sqlite3_reset(insert)
                    bind(insert, 1, wake.date.timeIntervalSince1970)
                    bind(insert, 2, wake.reason.rawValue)
                    bind(insert, 3, wake.detail)
                    bind(insert, 4, wake.seconds)
                    bind(insert, 5, Self.list(wake.holders))
                    bind(insert, 6, Self.list(wake.apps))
                    try step(insert)
                }
                try mark(loggedSessions, column: "wakes_logged")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Saves what the system log added to saved wakes (see `SystemLog`) and marks
    /// the sessions it was read for, or, when the read `failed`, tried for.
    public func annotate(_ wakes: [DarkWake], loggedSessions: [Int64], failed: Bool = false) throws {
        try locked {
            try execute("BEGIN")
            do {
                let update = try prepare("UPDATE dark_wakes SET reason = ?, apps = ? WHERE date = ?")
                defer { sqlite3_finalize(update) }
                for wake in wakes {
                    sqlite3_reset(update)
                    bind(update, 1, wake.reason.rawValue)
                    bind(update, 2, Self.list(wake.apps))
                    bind(update, 3, wake.date.timeIntervalSince1970)
                    try step(update)
                }
                try mark(loggedSessions, column: "apps_logged", value: failed ? Self.appsReadFailed : 1)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Lists are saved one item per line, or NULL when empty.
    private static func list(_ items: [String]) -> String? {
        items.isEmpty ? nil : items.joined(separator: "\n")
    }

    private static func list(_ text: String?) -> [String] {
        text?.split(separator: "\n").map(String.init) ?? []
    }

    /// `apps_logged` is 0 before the system log is read for a session, 1 once
    /// read, and this when the read failed.
    private static let appsReadFailed = 2

    private func mark(_ sessions: [Int64], column: String, value: Int = 1) throws {
        let mark = try prepare("UPDATE sleep_sessions SET \(column) = ? WHERE id = ?")
        defer { sqlite3_finalize(mark) }
        for id in sessions {
            sqlite3_reset(mark)
            bind(mark, 1, value)
            sqlite3_bind_int64(mark, 2, id)
            try step(mark)
        }
    }

    /// Saved brief wakes, oldest first.
    public func darkWakes() throws -> [DarkWake] {
        try locked {
            let statement = try prepare("""
                SELECT date, reason, detail, seconds, holders, apps FROM dark_wakes ORDER BY date
                """)
            defer { sqlite3_finalize(statement) }
            var result: [DarkWake] = []
            try forEachRow(statement) {
                result.append(DarkWake(
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    reason: text(statement, 1).flatMap(WakeReason.init(rawValue:)) ?? .other,
                    detail: text(statement, 2),
                    seconds: int(statement, 3),
                    holders: Self.list(text(statement, 4)),
                    apps: Self.list(text(statement, 5))))
            }
            return result
        }
    }

    /// Records the brief wakes counted for a session saved without them.
    public func setBriefWakes(_ count: Int, forSleepSession id: Int64) throws {
        try locked {
            let statement = try prepare("UPDATE sleep_sessions SET brief_wakes = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, count)
            sqlite3_bind_int64(statement, 2, id)
            try step(statement)
        }
    }

    /// Sleep sessions, newest first.
    public func sleepSessions() throws -> [SleepSession] {
        try locked {
            let statement = try prepare("""
                SELECT id, start, end, start_capacity, end_capacity, full_charge_capacity, brief_wakes,
                    wakes_logged, apps_logged
                FROM sleep_sessions ORDER BY end DESC
                """)
            defer { sqlite3_finalize(statement) }
            var result: [SleepSession] = []
            try forEachRow(statement) {
                // Skip rows that can't be shown, such as one saved from a damaged
                // backup before backups were checked.
                guard sqlite3_column_double(statement, 2) > sqlite3_column_double(statement, 1),
                      (int(statement, 5) ?? 0) > 0 else { return }
                result.append(SleepSession(
                    id: sqlite3_column_int64(statement, 0),
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    startCapacity: int(statement, 3) ?? 0,
                    endCapacity: int(statement, 4) ?? 0,
                    fullChargeCapacity: int(statement, 5) ?? 1,
                    briefWakes: int(statement, 6),
                    wakesLogged: int(statement, 7) == 1,
                    appsLogged: (int(statement, 8) ?? 0) != 0,
                    appsReadFailed: int(statement, 8) == Self.appsReadFailed))
            }
            return result
        }
    }

    // MARK: Power timeline

    /// Saves a minute and drops data older than `PowerTimeline.retention`.
    public func insert(_ minute: PowerMinute) throws {
        try locked {
            let statement = try prepare("""
                INSERT OR REPLACE INTO power_minutes (start, average_watts, peak_watts, charge_percent, on_adapter)
                VALUES (?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, minute.start.timeIntervalSince1970)
            bind(statement, 2, minute.averageWatts)
            bind(statement, 3, minute.peakWatts)
            bind(statement, 4, minute.chargePercent)
            bind(statement, 5, minute.onAdapter ? 1 : 0)
            try step(statement)
            try deleteBefore(minute.start.addingTimeInterval(-PowerTimeline.retention))
        }
    }

    /// Saved minutes since `date`, oldest first.
    public func powerMinutes(since date: Date) throws -> [PowerMinute] {
        try locked {
            let statement = try prepare("""
                SELECT start, average_watts, peak_watts, charge_percent, on_adapter
                FROM power_minutes WHERE start >= ? ORDER BY start
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, date.timeIntervalSince1970)
            var result: [PowerMinute] = []
            try forEachRow(statement) {
                result.append(PowerMinute(
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    averageWatts: sqlite3_column_double(statement, 1),
                    peakWatts: sqlite3_column_double(statement, 2),
                    chargePercent: int(statement, 3),
                    onAdapter: (int(statement, 4) ?? 0) != 0))
            }
            return result
        }
    }

    // MARK: App energy

    /// Adds usage to each app's total for the hour containing `date`, counting it
    /// as battery energy when `onBattery`, and drops hours older than
    /// `PowerTimeline.retention`.
    public func addAppUsage(_ usage: [String: AppUsage], at date: Date, onBattery: Bool) throws {
        guard !usage.isEmpty else { return }
        let hour = (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        try locked {
            try execute("BEGIN")
            do {
                let statement = try prepare("""
                    INSERT INTO app_energy (hour, app, joules, battery_joules, cpu_seconds) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(hour, app) DO UPDATE SET
                        joules = joules + excluded.joules,
                        battery_joules = battery_joules + excluded.battery_joules,
                        cpu_seconds = cpu_seconds + excluded.cpu_seconds
                    """)
                defer { sqlite3_finalize(statement) }
                for (app, used) in usage {
                    sqlite3_reset(statement)
                    bind(statement, 1, hour)
                    bind(statement, 2, app)
                    bind(statement, 3, used.joules)
                    bind(statement, 4, onBattery ? used.joules : 0)
                    bind(statement, 5, used.cpuSeconds)
                    try step(statement)
                }
                let prune = try prepare("DELETE FROM app_energy WHERE hour < ?")
                defer { sqlite3_finalize(prune) }
                bind(prune, 1, hour - PowerTimeline.retention)
                try step(prune)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Each app's usage in the hours from the one containing `date`, in total and
    /// on battery.
    public func appUsage(since date: Date) throws -> [(app: String, total: AppUsage, onBattery: AppUsage)] {
        try locked {
            let statement = try prepare("""
                SELECT app, SUM(joules), SUM(battery_joules), SUM(cpu_seconds) FROM app_energy
                WHERE hour >= ? GROUP BY app
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            var result: [(app: String, total: AppUsage, onBattery: AppUsage)] = []
            try forEachRow(statement) {
                guard let app = text(statement, 0) else { return }
                result.append((app, AppUsage(joules: sqlite3_column_double(statement, 1),
                                             cpuSeconds: sqlite3_column_double(statement, 3)),
                               AppUsage(joules: sqlite3_column_double(statement, 2))))
            }
            return result
        }
    }

    /// When app usage was first recorded, if it has been.
    public func appUsageStart() throws -> Date? {
        try locked {
            let statement = try prepare("SELECT MIN(hour) FROM app_energy")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL
            else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    /// Records a time the Mac was asleep, plugged in or not.
    public func insertSleepPeriod(_ period: DateInterval) throws {
        try locked {
            let statement = try prepare("INSERT OR REPLACE INTO sleep_periods (start, end) VALUES (?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, period.start.timeIntervalSince1970)
            bind(statement, 2, period.end.timeIntervalSince1970)
            try step(statement)
            try deleteBefore(period.end.addingTimeInterval(-PowerTimeline.retention))
        }
    }

    /// Sleeps that ended after `date`, oldest first.
    public func sleepPeriods(since date: Date) throws -> [DateInterval] {
        try locked {
            let statement = try prepare("SELECT start, end FROM sleep_periods WHERE end >= ? ORDER BY start")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, date.timeIntervalSince1970)
            var result: [DateInterval] = []
            try forEachRow(statement) {
                let start = sqlite3_column_double(statement, 0), end = sqlite3_column_double(statement, 1)
                guard end >= start else { return }
                result.append(DateInterval(start: Date(timeIntervalSince1970: start),
                                           end: Date(timeIntervalSince1970: end)))
            }
            return result
        }
    }

    /// Drops power minutes and sleep periods older than `date` (caller holds the lock).
    private func deleteBefore(_ date: Date) throws {
        let cutoff = date.timeIntervalSince1970
        try execute("""
            DELETE FROM power_minutes WHERE start < \(cutoff);
            DELETE FROM sleep_periods WHERE end < \(cutoff);
            """)
    }

    // MARK: Devices

    /// Devices with at least one entry, most recently saved first.
    public func devices(defaultAutoRecord: Bool) throws -> [HistoryDevice] {
        try locked {
            let statement = try prepare("""
                SELECT e.device_serial, e.device_name, e.device_model, e.device_type, COUNT(*), MAX(e.date), d.auto_record
                FROM entries e LEFT JOIN devices d ON d.serial = e.device_serial
                GROUP BY e.device_serial ORDER BY MAX(e.date) DESC
                """)
            defer { sqlite3_finalize(statement) }
            var result: [HistoryDevice] = []
            try forEachRow(statement) {
                result.append(HistoryDevice(
                    serial: text(statement, 0) ?? "",
                    name: text(statement, 1) ?? "",
                    model: text(statement, 2) ?? "",
                    type: HistoryEntry.DeviceType(rawValue: text(statement, 3) ?? "") ?? .mac,
                    entryCount: Int(sqlite3_column_int64(statement, 4)),
                    lastSaved: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    autoRecord: int(statement, 6).map { $0 != 0 } ?? defaultAutoRecord
                ))
            }
            return result
        }
    }

    /// The device's Auto-Record setting, or `nil` if it has never been set.
    public func autoRecord(deviceSerial: String) throws -> Bool? {
        try locked {
            let statement = try prepare("SELECT auto_record FROM devices WHERE serial = ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, deviceSerial)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    public func setAutoRecord(_ enabled: Bool, deviceSerial: String) throws {
        try locked {
            let statement = try prepare("INSERT OR REPLACE INTO devices (serial, auto_record) VALUES (?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, deviceSerial)
            bind(statement, 2, enabled ? 1 : 0)
            try step(statement)
        }
    }

    // MARK: Backup

    private struct Backup: Codable {
        var format = "citrus-battery-history"
        /// 1: entries only. 2: also sleep sessions and their brief wakes, which
        /// later gained optional durations, holders and apps.
        var version = 2
        var entries: [HistoryEntry]
        var sleepSessions: [BackupSleepSession]?
        var darkWakes: [DarkWake]?
    }

    private struct BackupSleepSession: Codable {
        var start: Date
        var end: Date
        var startCapacity: Int
        var endCapacity: Int
        var fullChargeCapacity: Int
        var briefWakes: Int?
        var wakesLogged: Bool?
        var appsLogged: Bool?
        var appsReadFailed: Bool?

        init(_ session: SleepSession) {
            start = session.start
            end = session.end
            startCapacity = session.startCapacity
            endCapacity = session.endCapacity
            fullChargeCapacity = session.fullChargeCapacity
            briefWakes = session.briefWakes
            wakesLogged = session.wakesLogged
            appsLogged = session.appsLogged
            appsReadFailed = session.appsReadFailed ? true : nil
        }

        /// Whether the session makes sense: it ends after it starts, and its
        /// capacities can be divided by and compared. A hand-edited or damaged
        /// backup could otherwise save a session that can't be shown.
        var isValid: Bool {
            start.timeIntervalSince1970.isFinite && end.timeIntervalSince1970.isFinite && end > start
                && fullChargeCapacity > 0 && (0...Self.maximumCapacity).contains(startCapacity)
                && (0...Self.maximumCapacity).contains(endCapacity)
                && fullChargeCapacity <= Self.maximumCapacity && (briefWakes ?? 0) >= 0
        }

        /// Well above any Mac battery (mAh), to catch nonsense rather than to judge.
        static let maximumCapacity = 100_000

        var session: SleepSession {
            SleepSession(start: start, end: end, startCapacity: startCapacity, endCapacity: endCapacity,
                         fullChargeCapacity: fullChargeCapacity, briefWakes: briefWakes,
                         wakesLogged: wakesLogged ?? false, appsLogged: appsLogged ?? false,
                         appsReadFailed: appsReadFailed ?? false)
        }
    }

    /// What an import added.
    public struct BackupImport: Sendable, Equatable {
        public var entries: Int
        public var sleepSessions: Int

        public init(entries: Int, sleepSessions: Int) {
            self.entries = entries
            self.sleepSessions = sleepSessions
        }
    }

    /// JSON backup of every entry, sleep session and saved brief wake.
    public func exportBackup() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Backup(entries: entries(),
                                         sleepSessions: sleepSessions().reversed().map(BackupSleepSession.init),
                                         darkWakes: darkWakes()))
    }

    /// Adds what a backup holds that isn't already here: entries (same device and
    /// time), sleep sessions (same start) and brief wakes (same time).
    @discardableResult
    public func importBackup(_ data: Data) throws -> BackupImport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(Backup.self, from: data),
              backup.format == "citrus-battery-history"
        else { throw HistoryError.unreadableBackup }
        // Check everything before writing anything, so a bad backup changes nothing.
        guard (backup.sleepSessions ?? []).allSatisfy(\.isValid),
              (backup.darkWakes ?? []).allSatisfy({ $0.date.timeIntervalSince1970.isFinite && ($0.seconds ?? 0) >= 0 })
        else { throw HistoryError.damagedBackup }
        let entries = try importEntries(backup.entries)
        var existing = Set(try sleepSessions().map { Int($0.start.timeIntervalSince1970) })
        var sessions = 0
        for session in (backup.sleepSessions ?? []).map(\.session)
        where existing.insert(Int(session.start.timeIntervalSince1970)).inserted {
            try insert(session)
            sessions += 1
        }
        try insert(backup.darkWakes ?? [], loggedSessions: [])
        return BackupImport(entries: entries, sleepSessions: sessions)
    }

    /// Adds entries, skipping ones already present (same device and second).
    /// Returns the number added.
    @discardableResult
    public func importEntries(_ newEntries: [HistoryEntry]) throws -> Int {
        func key(_ entry: HistoryEntry) -> String {
            "\(entry.deviceSerial)|\(Int(entry.date.timeIntervalSince1970))"
        }
        var existing = Set(try entries().map(key))
        var added = 0
        for var entry in newEntries where existing.insert(key(entry)).inserted {
            entry.id = 0
            try insert(entry)
            added += 1
        }
        return added
    }

    // MARK: SQLite helpers

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw HistoryError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError.database(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    /// Calls `row` for each row of a query, and throws if SQLite stops with an
    /// error partway, rather than handing back the rows read so far as if complete.
    private func forEachRow(_ statement: OpaquePointer?, _ row: () throws -> Void) throws {
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row()
            case SQLITE_DONE: return
            default: throw HistoryError.database(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// SQLite must copy bound strings because Swift's temporary buffers don't outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func int(_ statement: OpaquePointer?, _ column: Int32) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
    }
}

extension HistoryEntry {
    /// A Mac reading, ready to save.
    public init(mac info: MacInfo, name: String, battery: MacBatterySnapshot) {
        self.init(
            date: battery.date,
            deviceType: .mac,
            deviceSerial: info.serialNumber ?? info.modelIdentifier,
            deviceName: name,
            deviceModel: info.modelIdentifier,
            osVersion: info.osVersion
                .replacingOccurrences(of: "Version ", with: "")
                .replacingOccurrences(of: "Build ", with: ""),
            batterySerial: battery.serialNumber,
            cycleCount: battery.cycleCount,
            designCapacity: battery.designCapacity,
            fullChargeCapacity: battery.fullChargeCapacity
        )
    }
}

extension HistoryEntry {
    /// An iPhone or iPad reading, ready to save. Keyed by the device serial, or
    /// its UDID when the serial isn't available.
    public init(device: IOSDeviceSnapshot, battery: MacBatterySnapshot) {
        self.init(
            date: device.date,
            deviceType: .iOS,
            deviceSerial: device.serialNumber ?? device.udid,
            deviceName: device.name,
            deviceModel: device.productType,
            osVersion: device.osVersion,
            batterySerial: battery.serialNumber,
            cycleCount: battery.cycleCount,
            designCapacity: battery.designCapacity,
            fullChargeCapacity: battery.fullChargeCapacity
        )
    }
}
