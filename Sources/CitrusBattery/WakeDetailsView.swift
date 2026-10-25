import AppKit
import CitrusKit
import SwiftUI

/// Every brief wake during a set of sleeps: when, why, for how long, and what
/// ran or kept the Mac awake. Everything shown was saved after each sleep, so
/// opening it reads no logs.
struct WakeDetailsView: View {
    let title: String
    let sessions: [SleepSession]
    let wakes: [DarkWake]
    @Environment(\.dismiss) private var dismiss
    @ViewState private var sortOrder = [KeyPathComparator(\DarkWake.date, order: .reverse)]

    var body: some View {
        let breakdown = WakeBreakdown(wakes)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wake Details")
                    .font(.title3.weight(.semibold))
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 14)
            HStack(spacing: 12) {
                StatTile(title: "Brief Wakes", value: "\(breakdown.total)",
                         detail: sessions.count == 1 ? "in 1 sleep" : "in \(sessions.count) sleeps")
                StatTile(title: "Time Awake", value: breakdown.timedWakes > 0
                    ? Self.duration(seconds: breakdown.secondsAwake) : "—", detail: "with the screen off")
                StatTile(title: "Average Wake", value: breakdown.timedWakes > 0
                    ? Self.duration(seconds: breakdown.secondsAwake / breakdown.timedWakes) : "—",
                    detail: longest.map { "longest \(Self.duration(seconds: $0))" } ?? "")
            }
            .padding(.horizontal, 20)
            HStack(alignment: .top, spacing: 16) {
                RankedList(title: "Kept Awake By", items: merged(breakdown.holders.filter {
                    !WakeNames.housekeeping.contains($0.name)
                }.map {
                    (name: WakeNames.process($0.name), count: $0.count)
                }), empty: "Only macOS's own housekeeping.",
                    help: "What held the Mac awake, and in how many wakes. Power management and network "
                        + "presence take part in nearly every wake, so they aren't listed.")
                RankedList(title: "Apps Using iCloud or Downloads", items: merged(breakdown.apps.map {
                    (name: AppNames.name(for: $0.name), count: $0.count)
                }), empty: appsEmptyText,
                    help: "Apps that iCloud or background downloads worked for during the wakes.")
            }
            .padding(20)
            Divider()
            table
            Divider()
            HStack(alignment: .bottom, spacing: 16) {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 780, height: 640)
    }

    private var longest: Int? { wakes.compactMap(\.seconds).max() }

    /// As on the Sleep page: the year on every row once any wake is from another year.
    private var withYear: Bool {
        wakes.contains { !Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .year) }
    }

    /// Sleeps whose apps are known: the system log was read for them.
    private var appsKnown: [SleepSession] { sessions.filter { $0.appsLogged && !$0.appsReadFailed } }

    private var appsEmptyText: String {
        if !appsKnown.isEmpty { return "None during these wakes." }
        return sessions.contains(where: \.appsReadFailed) ? "Couldn't be read for these sleeps."
            : "Not available for these sleeps."
    }

    private var footnote: String {
        var note = "macOS doesn't say which app a push notification was for."
        if sessions.contains(where: { !$0.appsLogged }) {
            note += " Older sleeps don't have app names."
        }
        if !appsKnown.isEmpty, sessions.contains(where: \.appsReadFailed) {
            note += " App names couldn't be read for some sleeps."
        }
        return note
    }

    private var table: some View {
        Table(wakes.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Time", value: \.date) { wake in
                DateTimeCell(date: wake.date, withYear: withYear)
            }
            .width(min: 140, ideal: 150)
            TableColumn("Reason", value: \.reason.label) { wake in
                HStack(spacing: 5) {
                    Circle().fill(wake.reason.colour).frame(width: 8, height: 8)
                    Text(wake.reason.label)
                }
                .help(wake.reason.explanation)
            }
            .width(min: 130, ideal: 150)
            TableColumn("Awake", value: \.secondsSortKey) { wake in
                Text(wake.seconds.map { Self.duration(seconds: $0) } ?? "—").monospacedDigit()
            }
            .width(60)
            TableColumn("For") { wake in
                let ran = ([wake.detail].compactMap { $0 } + wake.apps.map(AppNames.name(for:)))
                    .joined(separator: ", ")
                Text(ran.isEmpty ? "—" : ran)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ran)
            }
            .width(min: 120, ideal: 230)
            TableColumn("Kept Awake By") { wake in
                let names = merged(wake.holders.filter { !WakeNames.housekeeping.contains($0) }
                    .map { (name: WakeNames.process($0), count: 1) }).map(\.name)
                Text(names.isEmpty ? "—" : names.joined(separator: ", "))
                    .lineLimit(1)
                    .help(names.joined(separator: "\n"))
            }
        }
    }

    /// Joins items that read the same once named, such as two Spotlight processes.
    private func merged(_ items: [(name: String, count: Int)]) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            if counts[item.name] == nil { order.append(item.name) }
            counts[item.name, default: 0] += item.count
        }
        return order.map { (name: $0, count: counts[$0] ?? 0) }.sorted { $0.count > $1.count }
    }

    /// "7 s", "4 min", "1 h 38 min".
    static func duration(seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : DurationFormat.readable(Int((Double(seconds) / 60).rounded()))
    }
}

/// Names with counts and a bar for each one's share of the largest.
private struct RankedList: View {
    let title: String
    let items: [(name: String, count: Int)]
    let empty: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .help(help)
            if items.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(items.prefix(5), id: \.name) { item in
                HStack {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(item.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// App names for bundle identifiers, looked up once each.
@MainActor
enum AppNames {
    private static var cache: [String: String] = [:]

    static func name(for bundleID: String) -> String {
        if let name = cache[bundleID] { return name }
        let name = WakeNames.agent(bundleID)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
            ?? bundleID
        cache[bundleID] = name
        return name
    }
}

private extension DarkWake {
    /// Unknown durations sort first.
    var secondsSortKey: Int { seconds ?? -1 }
}
