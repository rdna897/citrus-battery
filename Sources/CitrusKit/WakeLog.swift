import Foundation

/// Why macOS woke the Mac briefly with the screen off.
public enum WakeReason: String, CaseIterable, Sendable, Codable {
    /// A timer set by macOS's background task scheduler (dasd) or another process.
    case scheduledTask
    /// mDNSResponder renewing the Mac's network presence (Bonjour, Wake for network access).
    case networkUpkeep
    /// Wi-Fi or Bluetooth traffic, such as a network packet or a Bluetooth device.
    case wireless
    /// A power adapter connected or disconnected.
    case power
    case other

    public var label: String {
        switch self {
        case .scheduledTask: "Scheduled tasks"
        case .networkUpkeep: "Network upkeep"
        case .wireless: "Wi-Fi or Bluetooth"
        case .power: "Power adapter"
        case .other: "Other"
        }
    }

    /// What it means, for help text.
    public var explanation: String {
        switch self {
        case .scheduledTask: "macOS woke the Mac to run background work an app or macOS scheduled."
        case .networkUpkeep: "macOS renewed the Mac's network presence so it stays reachable, for "
            + "example for Wake for network access."
        case .wireless: "Wi-Fi or Bluetooth activity woke the Mac, such as network traffic or a Bluetooth device."
        case .power: "A power adapter was connected or disconnected."
        case .other: "Another hardware or system event woke the Mac."
        }
    }
}

/// A brief wake from macOS's power log.
public struct DarkWake: Sendable, Equatable, Codable {
    public var date: Date
    public var reason: WakeReason
    /// What scheduled it, for scheduled wakes: the task's identifier, such as
    /// "com.apple.intelligenceflow.toolbox.update.fastpass", or the process.
    public var detail: String?

    public init(date: Date, reason: WakeReason, detail: String? = nil) {
        self.date = date
        self.reason = reason
        self.detail = detail
    }
}

/// Reads brief wakes from `pmset -g log`, which macOS keeps for about a week
/// and which needs no administrator rights.
public enum WakeLog {
    /// The log's text, or `nil` if pmset couldn't run.
    public static func read() -> String? {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["-g", "log"]
        let output = Pipe()
        pmset.standardOutput = output
        pmset.standardError = FileHandle.nullDevice
        guard (try? pmset.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        pmset.waitUntilExit()
        return pmset.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// The log's brief wakes in order, and the time its records begin.
    public static func parse(_ log: String) -> (wakes: [DarkWake], since: Date?) {
        var wakes: [DarkWake] = []
        var since: Date?
        // The wake macOS last scheduled: the request it marks with "*" as sleep begins.
        var scheduled: (request: String, detail: String)?
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 26, let date = timestamp.date(from: String(line.prefix(25))) else { continue }
            since = since ?? date
            let rest = line.dropFirst(26)
            guard let tab = rest.firstIndex(of: "\t") else { continue }
            let domain = rest[..<tab].trimmingCharacters(in: .whitespaces)
            let message = rest[rest.index(after: tab)...]
            switch domain {
            case "Wake Requests":
                scheduled = starredRequest(in: message)
            case "DarkWake":
                wakes.append(darkWake(at: date, message: message, scheduled: scheduled))
            default:
                break
            }
        }
        return (wakes, since)
    }

    private static func darkWake(at date: Date, message: Substring,
                                 scheduled: (request: String, detail: String)?) -> DarkWake {
        let cause = message.range(of: "due to ").map { message[$0.upperBound...] } ?? message
        let words = cause.split(separator: " ")
        if words.contains(where: { $0.hasSuffix("rtc/Maintenance") }) {
            return DarkWake(date: date, reason: .networkUpkeep,
                            detail: scheduled?.request == "Maintenance" ? scheduled?.detail : nil)
        }
        if words.contains(where: { $0.contains("rtc/") }) {
            return DarkWake(date: date, reason: .scheduledTask, detail: scheduled?.detail)
        }
        if words.contains("wifibt") {
            return DarkWake(date: date, reason: .wireless)
        }
        if words.contains(where: { $0.contains("plug") || $0.lowercased().contains("acattach") }) {
            return DarkWake(date: date, reason: .power)
        }
        return DarkWake(date: date, reason: .other)
    }

    /// `[*process=dasd request=SleepService … info="com.apple.dasd:501:com.apple.x"]`
    /// → ("SleepService", "com.apple.x").
    private static func starredRequest(in message: Substring) -> (request: String, detail: String)? {
        guard let start = message.range(of: "[*process=") else { return nil }
        let entry = message[start.upperBound...].prefix { $0 != "]" }
        let process = String(entry.prefix { $0 != " " })
        let request = value(of: "request=", in: entry, until: " ") ?? ""
        let info = value(of: "info=\"", in: entry, until: "\"")
        return (request, info.map(taskName) ?? process)
    }

    private static func value(of key: String, in text: Substring, until end: Character) -> String? {
        guard let range = text.range(of: key) else { return nil }
        return String(text[range.upperBound...].prefix { $0 != end })
    }

    /// Strips the scheduler's prefixes and suffixes from a task identifier:
    /// "com.apple.dasd:501:com.apple.x" → "com.apple.x";
    /// "com.apple.alarm.user-invisible-com.apple.acmd.alarm,532" → "com.apple.acmd.alarm".
    static func taskName(_ info: String) -> String {
        var name = Substring(info)
        if let colon = name.lastIndex(of: ":") { name = name[name.index(after: colon)...] }
        for prefix in ["com.apple.alarm.user-invisible-", "com.apple.alarm.user-visible-"] where name.hasPrefix(prefix) {
            name = name.dropFirst(prefix.count)
        }
        if let comma = name.lastIndex(of: ","), name[name.index(after: comma)...].allSatisfy(\.isNumber) {
            name = name[..<comma]
        }
        return String(name)
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()
}

/// Brief wakes during a set of sleeps, by reason and by scheduled task.
public struct WakeBreakdown: Sendable, Equatable {
    public var total: Int
    /// Most frequent first.
    public var reasons: [(reason: WakeReason, count: Int)]
    /// Scheduled tasks, most frequent first.
    public var tasks: [(name: String, count: Int)]

    public init(_ wakes: [DarkWake]) {
        total = wakes.count
        reasons = Dictionary(grouping: wakes, by: \.reason)
            .map { (reason: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.reason.rawValue) > ($1.count, $0.reason.rawValue) }
        tasks = Dictionary(grouping: wakes.filter { $0.reason == .scheduledTask }.compactMap(\.detail), by: { $0 })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The wakes that fall within the sessions, in one pass over both sorted by time.
    public static func wakes(_ wakes: [DarkWake], during sessions: [SleepSession]) -> [DarkWake] {
        let intervals = sessions.map(\.interval).sorted { $0.start < $1.start }
        var result: [DarkWake] = []
        var index = 0
        for wake in wakes {
            while index < intervals.count, intervals[index].end < wake.date { index += 1 }
            guard index < intervals.count else { break }
            if intervals[index].contains(wake.date) { result.append(wake) }
        }
        return result
    }

    public static func == (lhs: WakeBreakdown, rhs: WakeBreakdown) -> Bool {
        lhs.total == rhs.total && lhs.reasons.elementsEqual(rhs.reasons) { $0 == $1 }
            && lhs.tasks.elementsEqual(rhs.tasks) { $0 == $1 }
    }
}
