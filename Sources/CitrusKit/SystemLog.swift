import Foundation

/// What macOS's system log adds to the power log's brief wakes: which apps
/// iCloud and background downloads worked for, and push notifications arriving.
///
/// Reading the log is the costliest thing Citrus Battery does in the background
/// (several seconds of CPU per sleep), so each sleep is read once, soon enough
/// that the log still covers it, and the result is saved.
public enum SystemLog {
    public enum Event: Sendable, Equatable {
        /// A push notification arrived. macOS hides which app it was for.
        case push(Date)
        /// iCloud or the background download service worked for an app.
        case app(Date, bundleID: String)

        var date: Date {
            switch self {
            case let .push(date), let .app(date, _): date
            }
        }
    }

    /// Only the two kinds of message used, so `log` filters before formatting.
    static let predicate = #"(process == "nsurlsessiond" AND eventMessage CONTAINS "acting on behalf of")"#
        + #" OR (process == "apsd" AND eventMessage CONTAINS "Received message for enabled topic")"#

    /// The log's messages between two dates as JSON lines, or `nil` if `log`
    /// couldn't run or took longer than `timeout`. Runs at background priority.
    public static func read(from start: Date, to end: Date, timeout: TimeInterval = 120) -> String? {
        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        log.arguments = ["show", "--style", "ndjson", "--predicate", predicate,
                         "--start", argumentFormat.string(from: start), "--end", argumentFormat.string(from: end)]
        log.qualityOfService = .background
        let output = Pipe()
        log.standardOutput = output
        log.standardError = FileHandle.nullDevice
        guard (try? log.run()) != nil else { return nil }
        let deadline = DispatchWorkItem { if log.isRunning { log.terminate() } }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        log.waitUntilExit()
        deadline.cancel()
        guard log.terminationReason == .exit, log.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ ndjson: String) -> [Event] {
        ndjson.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let stamp = object["timestamp"] as? String,
                  let date = timestamp.date(from: stamp)
            else { return nil }
            if message.contains("Received message for enabled topic") { return .push(date) }
            return app(in: message).map { .app(date, bundleID: $0) }
        }
    }

    /// "… Client com.apple.cloudd is acting on behalf of com.apple.Photos" → "com.apple.Photos";
    /// the client when what follows isn't a bundle identifier.
    static func app(in message: String) -> String? {
        guard let range = message.range(of: " is acting on behalf of ") else { return nil }
        let behalf = message[range.upperBound...].prefix { !$0.isWhitespace }
        if behalf.contains(".") { return String(behalf) }
        guard let client = message[..<range.lowerBound].split(separator: " ").last,
              client.contains("."), client != "com.apple.cloudd", client != "com.apple.nsurlsessiond"
        else { return nil }
        return String(client)
    }

    /// The wakes with the apps worked for during each, and Wi-Fi wakes during
    /// which a push notification arrived marked as push notifications.
    public static func annotate(_ wakes: [DarkWake], with events: [Event]) -> [DarkWake] {
        let events = events.sorted { $0.date < $1.date }
        var first = 0
        return wakes.map { wake in
            var wake = wake
            // Power log times are whole seconds, and its durations rounded down.
            let start = wake.date.addingTimeInterval(-1)
            let end = wake.date.addingTimeInterval((TimeInterval(wake.seconds ?? 0) + 3))
            while first < events.count, events[first].date < start { first += 1 }
            var index = first
            while index < events.count, events[index].date <= end {
                switch events[index] {
                case .push:
                    if wake.reason == .wireless { wake.reason = .pushNotification }
                case let .app(_, bundleID):
                    if !wake.apps.contains(bundleID) { wake.apps.append(bundleID) }
                }
                index += 1
            }
            return wake
        }
    }

    private static let argumentFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return formatter
    }()

    /// "2026-10-25 00:31:28.384585+0100".
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()
}

/// Plain names for the processes and agents that appear in wake details.
public enum WakeNames {
    /// "cloudd" → "iCloud sync"; other processes as they are.
    public static func process(_ name: String) -> String {
        processes[name] ?? name
    }

    /// Processes that take part in nearly every wake, so naming them says nothing
    /// about a particular one: macOS's power management, and mDNSResponder, which
    /// holds the Mac awake briefly at each wake to renew its network presence.
    public static let housekeeping: Set<String> = ["powerd", "mDNSResponder"]

    /// Names for system agents with no app to look up.
    public static func agent(_ bundleID: String) -> String? {
        agents[bundleID]
    }

    private static let processes = [
        "cloudd": "iCloud sync",
        "cloudtelemetryd": "iCloud diagnostics",
        "mDNSResponder": "Network presence (Bonjour)",
        "powerd": "macOS power management",
        "nsurlsessiond": "Background downloads",
        "apsd": "Push notifications",
        "dasd": "Background task scheduler",
        "backupd": "Time Machine",
        "softwareupdated": "Software Update",
        "sharingd": "AirDrop and Handoff",
        "rapportd": "Nearby devices",
        "bluetoothd": "Bluetooth",
        "Phone": "Phone and FaceTime calls",
        "PowerUIAgent": "Optimised charging",
        "nfcd": "Apple Pay (NFC)",
        "seld": "Apple Pay",
        "WindowServer": "Display",
        "loginwindow": "Login window",
        "PowerChime": "Charging sound",
        "locationd": "Location Services",
        "mds": "Spotlight",
        "mds_stores": "Spotlight",
    ]

    private static let agents = [
        "com.apple.UsageTrackingAgent": "Screen Time",
        "com.apple.syncdefaultsd": "Settings sync",
        "com.apple.weather.WeatherAppIntents": "Weather",
        "com.apple.shortcuts": "Shortcuts",
        "com.apple.bird": "iCloud Drive",
        "com.apple.cloudphotod": "Photos",
    ]
}
