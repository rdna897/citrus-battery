import Foundation

/// Why macOS woke the Mac briefly with the screen off.
public enum WakeReason: String, CaseIterable, Sendable, Codable {
    /// A timer set by macOS's background task scheduler (dasd) or another process.
    case scheduledTask
    /// mDNSResponder renewing the Mac's network presence (Bonjour, Wake for network access).
    case networkUpkeep
    /// Wi-Fi or Bluetooth traffic, such as a network packet or a Bluetooth device.
    case wireless
    /// A push notification arriving over Wi-Fi, found in the system log (see `SystemLog`).
    case pushNotification
    /// A power adapter connected or disconnected.
    case power
    case other

    public var label: String {
        switch self {
        case .scheduledTask: "Scheduled tasks"
        case .networkUpkeep: "Network upkeep"
        case .wireless: "Wi-Fi or Bluetooth"
        case .pushNotification: "Push notifications"
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
        case .pushNotification: "A push notification for an app or macOS service arrived over Wi-Fi. macOS "
            + "doesn't record which app it was for."
        case .power: "A power adapter was connected or disconnected."
        case .other: "Another hardware or system event woke the Mac."
        }
    }
}

/// A brief wake from macOS's power log.
public struct DarkWake: Sendable, Equatable, Codable, Identifiable {
    public var date: Date
    public var reason: WakeReason
    /// What scheduled it, for scheduled wakes: the task's identifier, such as
    /// "com.apple.intelligenceflow.toolbox.update.fastpass", or the process.
    public var detail: String?
    /// How long the Mac stayed awake; `nil` for wakes saved before this was read.
    public var seconds: Int?
    /// Processes that kept the Mac awake during the wake (power assertions), such as "cloudd".
    public var holders: [String]
    /// Apps that iCloud or background downloads worked for during the wake, by
    /// bundle identifier, from the system log.
    public var apps: [String]

    public init(date: Date, reason: WakeReason, detail: String? = nil, seconds: Int? = nil,
                holders: [String] = [], apps: [String] = []) {
        self.date = date
        self.reason = reason
        self.detail = detail
        self.seconds = seconds
        self.holders = holders
        self.apps = apps
    }

    /// Wakes are saved by time, which is unique.
    public var id: Date { date }

    private enum CodingKeys: String, CodingKey { case date, reason, detail, seconds, holders, apps }

    // Backups from before durations and holders were saved lack them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        reason = try container.decode(WakeReason.self, forKey: .reason)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        seconds = try container.decodeIfPresent(Int.self, forKey: .seconds)
        holders = try container.decodeIfPresent([String].self, forKey: .holders) ?? []
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
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
        // Efficiency cores and throttled disk reads: nothing waits on it.
        pmset.qualityOfService = .background
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
        // The latest wake and when it ended, to credit power assertions made during it.
        var awakeUntil: Date?
        // Assertions since the latest wake: ones made as a wake begins are logged
        // just before it, in the same second.
        var recent: [(date: Date, holder: String)] = []
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
                var wake = darkWake(at: date, message: message, scheduled: scheduled)
                for item in recent where item.date >= date.addingTimeInterval(-1)
                    && !wake.holders.contains(item.holder) {
                    wake.holders.append(item.holder)
                }
                recent = []
                wakes.append(wake)
                // Logged seconds are rounded down, and assertions can trail by a moment.
                awakeUntil = date.addingTimeInterval(TimeInterval((wake.seconds ?? 0) + 2))
            case "Assertions":
                guard let holder = assertionHolder(in: message) else { break }
                guard let until = awakeUntil, date <= until else {
                    recent.append((date, holder))
                    break
                }
                if !wakes[wakes.count - 1].holders.contains(holder) {
                    wakes[wakes.count - 1].holders.append(holder)
                }
            default:
                break
            }
        }
        return (wakes, since)
    }

    private static func darkWake(at date: Date, message: Substring,
                                 scheduled: (request: String, detail: String)?) -> DarkWake {
        var wake = darkWakeReason(at: date, message: message, scheduled: scheduled)
        // "… Using BATT (Charge:80%) 7 secs"
        let words = message.split(separator: " ")
        if words.last == "secs", words.count > 1 { wake.seconds = Int(words[words.count - 2]) }
        return wake
    }

    /// `PID 624(cloudd) Created SystemIsActive "…"` → "cloudd". Only assertions
    /// created then: ones released or timed out were made before the wake.
    private static func assertionHolder(in message: Substring) -> String? {
        guard message.hasPrefix("PID "), let open = message.firstIndex(of: "("),
              let close = message[open...].firstIndex(of: ")"),
              message[close...].hasPrefix(") Created ") else { return nil }
        return String(message[message.index(after: open)..<close])
    }

    private static func darkWakeReason(at date: Date, message: Substring,
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
    /// Time spent awake, over the wakes whose duration is known.
    public var secondsAwake: Int
    /// How many wakes have a known duration.
    public var timedWakes: Int
    /// Processes that kept the Mac awake, by the number of wakes they did so in.
    public var holders: [(name: String, count: Int)]
    /// Apps iCloud or background downloads worked for, by bundle identifier and wakes.
    public var apps: [(name: String, count: Int)]

    public init(_ wakes: [DarkWake]) {
        total = wakes.count
        reasons = Dictionary(grouping: wakes, by: \.reason)
            .map { (reason: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.reason.rawValue) > ($1.count, $0.reason.rawValue) }
        tasks = Self.ranked(wakes.filter { $0.reason == .scheduledTask }.compactMap(\.detail))
        let timed = wakes.compactMap(\.seconds)
        secondsAwake = timed.reduce(0, +)
        timedWakes = timed.count
        holders = Self.ranked(wakes.flatMap(\.holders))
        apps = Self.ranked(wakes.flatMap(\.apps))
    }

    /// Most frequent first, then by name.
    private static func ranked(_ names: [String]) -> [(name: String, count: Int)] {
        Dictionary(grouping: names, by: { $0 })
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
            && lhs.secondsAwake == rhs.secondsAwake && lhs.timedWakes == rhs.timedWakes
            && lhs.holders.elementsEqual(rhs.holders) { $0 == $1 }
            && lhs.apps.elementsEqual(rhs.apps) { $0 == $1 }
    }
}
