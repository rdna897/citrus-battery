import Foundation

/// Bounds catch damaged records while allowing far more than a Mac battery can hold.
enum HistoryValidation {
    static let maximumCapacity = 100_000
    static let maximumCount = 1_000_000
    static let maximumWakeSeconds = 7 * 86_400

    static let dates: ClosedRange<Double> = -62_135_596_800...253_402_300_799
    static let dataVersions = 1...1000

    static func date(_ date: Date) -> Bool {
        dates.contains(date.timeIntervalSince1970)
    }

    static func entry(_ entry: HistoryEntry) -> Bool {
        date(entry.date) && !entry.deviceSerial.isEmpty
            && (entry.cycleCount.map { (0...maximumCount).contains($0) } ?? true)
            && (entry.designCapacity.map { (1...maximumCapacity).contains($0) } ?? true)
            && (entry.fullChargeCapacity.map { (0...maximumCapacity).contains($0) } ?? true)
            && dataVersions.contains(entry.dataVersion)
    }

    /// A reading with any out-of-range figures left out, so a device that
    /// reports, say, a design capacity of 0 still gets its reading saved; nil
    /// when what identifies it (date, serial, data version) isn't usable.
    static func reading(_ entry: HistoryEntry) -> HistoryEntry? {
        var entry = entry
        if let count = entry.cycleCount, !(0...maximumCount).contains(count) { entry.cycleCount = nil }
        if let design = entry.designCapacity, !(1...maximumCapacity).contains(design) { entry.designCapacity = nil }
        if let full = entry.fullChargeCapacity, !(0...maximumCapacity).contains(full) {
            entry.fullChargeCapacity = nil
        }
        return Self.entry(entry) ? entry : nil
    }

    static func session(_ session: SleepSession) -> Bool {
        date(session.start) && date(session.end) && session.end > session.start
            && session.end.timeIntervalSince(session.start) <= 366 * 86_400
            && (0...maximumCapacity).contains(session.startCapacity)
            && (0...maximumCapacity).contains(session.endCapacity)
            && (1...maximumCapacity).contains(session.fullChargeCapacity)
            && (0...maximumCount).contains(session.briefWakes ?? 0)
    }

    static func wake(_ wake: DarkWake) -> Bool {
        date(wake.date) && (0...maximumWakeSeconds).contains(wake.seconds ?? 0)
    }
}
