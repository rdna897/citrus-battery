import Foundation
import IOKit.pwr_mgt

/// An app keeping the Mac from going to sleep on its own.
public struct SleepBlocker: Sendable, Equatable, Identifiable {
    /// The app, by path (see `AppEnergyMeter.owner(of:)`).
    public var owner: String
    /// The process holding the assertion when it isn't the app itself, such as
    /// "caffeinate" run from Terminal.
    public var process: String?
    /// What the app said it's doing, when it said so in words.
    public var reason: String?
    /// Only keeping the display on (which also stops the Mac sleeping), as video does.
    public var keepsDisplayOn: Bool
    public var since: Date

    public var id: String { owner }

    public init(owner: String, process: String? = nil, reason: String? = nil, keepsDisplayOn: Bool = false,
                since: Date) {
        self.owner = owner
        self.process = process
        self.reason = reason
        self.keepsDisplayOn = keepsDisplayOn
        self.since = since
    }
}

/// Reads which apps are preventing sleep, from macOS's power assertions. The
/// call asks powerd for its current list, so it's cheap; it's still only made
/// while something showing the list is open.
public enum SleepBlockers {
    /// Assertions held for less than this are passing work, not worth naming.
    public static let minimumAge: TimeInterval = 60

    static let systemTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
    /// powerd holds the Mac awake whenever the display is on, and WindowServer
    /// while the user is active; neither is an app preventing sleep.
    static let ignoredProcesses: Set<String> = ["powerd", "WindowServer"]

    /// Apps preventing sleep, longest first.
    public static func current(now: Date = Date()) -> [SleepBlocker] {
        var all: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&all) == kIOReturnSuccess,
              let byProcess = all?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let assertions = byProcess.values.flatMap { $0 }
        return blockers(from: assertions, now: now) { AppEnergyMeter.owner(of: $0) }
    }

    /// Groups assertions by app. `owner` maps a process ID to its app.
    static func blockers(from assertions: [[String: Any]], now: Date,
                         owner: (pid_t) -> String) -> [SleepBlocker] {
        var byOwner: [String: SleepBlocker] = [:]
        for assertion in assertions {
            guard let type = assertion["AssertType"] as? String,
                  systemTypes.contains(type) || displayTypes.contains(type),
                  let pid = (assertion["AssertPID"] as? NSNumber)?.int32Value,
                  pid != getpid() else { continue }
            let process = assertion["Process Name"] as? String ?? ""
            guard !ignoredProcesses.contains(process) else { continue }
            let since = assertion["AssertStartWhen"] as? Date ?? now
            guard now.timeIntervalSince(since) >= minimumAge else { continue }
            // coreaudiod holds the assertion for whichever app is playing audio.
            let behalf = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
            let app = owner(behalf.flatMap { $0 > 0 ? $0 : nil } ?? pid)
            let blocker = SleepBlocker(
                owner: app,
                process: behalf == nil && !app.hasSuffix("/\(process).app") && !app.hasSuffix("/\(process)")
                    && !process.isEmpty ? process : nil,
                reason: reason(assertion, process: process, onBehalf: behalf != nil),
                keepsDisplayOn: displayTypes.contains(type),
                since: since)
            if var existing = byOwner[app] {
                // Keeping the Mac awake outranks keeping the display on.
                existing.keepsDisplayOn = existing.keepsDisplayOn && blocker.keepsDisplayOn
                if blocker.since < existing.since { existing.since = blocker.since }
                existing.reason = existing.reason ?? blocker.reason
                existing.process = existing.process ?? blocker.process
                byOwner[app] = existing
            } else {
                byOwner[app] = blocker
            }
        }
        return byOwner.values.sorted { ($0.since, $0.owner) < ($1.since, $1.owner) }
    }

    /// The reason in words, or nil when it's an identifier such as
    /// "com.apple.audio.context.preventuseridlesleep".
    static func reason(_ assertion: [String: Any], process: String, onBehalf: Bool) -> String? {
        if onBehalf && process == "coreaudiod" { return "Playing audio" }
        // The name the app gave the assertion, which is usually its own words;
        // the "human-readable" one is often a canned sentence in capitals.
        let text = (assertion["AssertName"] as? String) ?? (assertion["HumanReadableReason"] as? String)
        guard let text, text.contains(" "), !text.hasPrefix("com."),
              process.isEmpty || !text.localizedCaseInsensitiveContains(process) else { return nil }
        return text
    }
}
