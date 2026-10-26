import AppKit
import CitrusKit
import SwiftUI

/// Names and icons for apps identified by path (see `AppEnergyMeter.owner(of:)`),
/// looked up once each.
@MainActor
enum AppIdentity {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    /// "Google Chrome" for "/Applications/Google Chrome.app"; a plain name for
    /// processes outside apps, such as "Spotlight" for mdworker_shared.
    static func name(_ path: String) -> String {
        if let name = names[path] { return name }
        let name: String
        if path.hasSuffix(".app") {
            let bundle = Bundle(path: path)
            name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String
                ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        } else {
            name = WakeNames.process((path as NSString).lastPathComponent)
        }
        names[path] = name
        return name
    }

    static func icon(_ path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: .unixExecutable)
        icons[path] = icon
        return icon
    }
}

/// Which apps used the most energy over a period, from Citrus Battery's own
/// once-a-minute readings.
struct AppEnergyCard: View {
    @EnvironmentObject private var history: HistoryController
    @AppStorage(PreferenceKey.appEnergyPeriod) private var period = AppEnergyPeriod.day
    @AppStorage(PreferenceKey.appEnergyBatteryOnly) private var batteryOnly = false
    @ViewState private var apps: [(app: String, usage: AppUsage)] = []
    @ViewState private var since: Date?
    private let refresh = Timer.publish(every: 60, tolerance: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Card(title: "Energy by App", systemImage: "chart.bar.xaxis") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Period", selection: $period) {
                        ForEach(AppEnergyPeriod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Toggle("On battery only", isOn: $batteryOnly)
                        .toggleStyle(.checkbox)
                }
                .controlSize(.small)
                let ranked = rankedApps
                if ranked.isEmpty {
                    Text(since == nil ? "Citrus Battery starts measuring now; check back in a few minutes."
                        : batteryOnly ? "No energy used on battery in this period." : "Nothing measured in this period.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let total = ranked.reduce(0) { $0 + value($1.usage) }
                    VStack(spacing: 8) {
                        ForEach(ranked.prefix(8), id: \.app) { item in
                            AppEnergyRow(app: item.app, text: text(item.usage),
                                         fraction: value(item.usage) / max(value(ranked[0].usage), .leastNonzeroMagnitude),
                                         share: value(item.usage) / max(total, .leastNonzeroMagnitude))
                        }
                    }
                }
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: period) { _ in load() }
        .onChange(of: batteryOnly) { _ in load() }
        .onReceive(refresh) { _ in load() }
    }

    private func load() {
        let selected = period
        let onBatteryOnly = batteryOnly
        Task {
            let result = await history.appEnergy(period: selected, onBatteryOnly: onBatteryOnly)
            guard period == selected, batteryOnly == onBatteryOnly else { return }
            apps = result.apps
            since = result.since
        }
    }

    /// Intel Macs don't measure energy per process, so rank by processor time there.
    private var measuresEnergy: Bool { apps.contains { $0.usage.joules > 0 } }

    private func value(_ usage: AppUsage) -> Double {
        measuresEnergy ? usage.joules : usage.cpuSeconds
    }

    private var rankedApps: [(app: String, usage: AppUsage)] {
        apps.filter { value($0.usage) > 0 }.sorted { value($0.usage) > value($1.usage) }
    }

    /// "1.2 Wh", "350 mWh", or processor time where energy isn't measured.
    private func text(_ usage: AppUsage) -> String {
        guard measuresEnergy else {
            return usage.cpuSeconds < 60 ? String(format: "%.0f s", usage.cpuSeconds)
                : DurationFormat.readable(Int((usage.cpuSeconds / 60).rounded()))
        }
        let wattHours = usage.joules / 3600
        switch wattHours {
        case 1...: return String(format: "%.1f Wh", wattHours)
        case 0.01...: return String(format: "%.0f mWh", wattHours * 1000)
        default: return String(format: "%.1f mWh", wattHours * 1000)
        }
    }

    private var footnote: String {
        var note = measuresEnergy ? "Processor energy" : "Processor time"
        if let since, since > Date().addingTimeInterval(-period.duration) {
            note += ", measured since " + since.formatted(date: .abbreviated, time: .shortened)
        }
        return note + ". macOS's own background processes aren't included."
    }
}

private struct AppEnergyRow: View {
    let app: String
    let text: String
    let fraction: Double
    let share: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIdentity.icon(app))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(AppIdentity.name(app))
                        .lineLimit(1)
                        .help(app)
                    Spacer(minLength: 8)
                    Text("\(text) · \(Int((share * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(geometry.size.width * fraction, 3))
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

/// Polls which apps are preventing sleep while something showing them is open.
@MainActor
final class SleepBlockerMonitor: ObservableObject {
    @Published private(set) var blockers: [SleepBlocker] = []
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 2
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        Task.detached(priority: .utility) {
            let blockers = SleepBlockers.current()
            await MainActor.run { [weak self] in
                if self?.blockers != blockers { self?.blockers = blockers }
            }
        }
    }
}

enum SleepBlockerText {
    /// "Keeping your Mac awake · Playing audio · 12 min".
    static func detail(_ blocker: SleepBlocker, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(blocker.since) / 60)
        return [blocker.keepsDisplayOn ? "Keeping the display on" : "Keeping your Mac awake",
                blocker.process, blocker.reason, minutes >= 1 ? DurationFormat.readable(minutes) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Apps preventing sleep right now.
struct PreventingSleepCard: View {
    let blockers: [SleepBlocker]

    var body: some View {
        Card(title: "Preventing Sleep", systemImage: "cup.and.saucer.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blockers) { blocker in
                    HStack(spacing: 8) {
                        Image(nsImage: AppIdentity.icon(blocker.owner))
                            .resizable()
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AppIdentity.name(blocker.owner))
                            Text(SleepBlockerText.detail(blocker))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("While an app does this, the Mac won't go to sleep on its own, which uses more battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
