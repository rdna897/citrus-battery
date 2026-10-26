import Foundation

/// Bounds catch damaged records while allowing far more than a Mac battery can hold.
enum HistoryValidation {
    static let maximumCapacity = 100_000
    static let maximumCount = 1_000_000
    static let maximumWakeSeconds = 7 * 86_400

    static func date(_ date: Date) -> Bool {
        (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }

    static func entry(_ entry: HistoryEntry) -> Bool {
        date(entry.date) && !entry.deviceSerial.isEmpty
            && (entry.cycleCount.map { (0...maximumCount).contains($0) } ?? true)
            && (entry.designCapacity.map { (1...maximumCapacity).contains($0) } ?? true)
            && (entry.fullChargeCapacity.map { (0...maximumCapacity).contains($0) } ?? true)
            && (1...1000).contains(entry.dataVersion)
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
