import Charts
import CitrusKit
import SwiftUI

/// This Mac's sleeps on battery over a chosen period: how fast they drained the
/// battery, how often macOS woke the Mac briefly, and each sleep in a table.
struct SleepView: View {
    @EnvironmentObject private var history: HistoryController
    @AppStorage(PreferenceKey.sleepPeriod) private var period = SleepPeriod.month
    @ViewState private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @ViewState private var to = Date()
    @ViewState private var sortOrder = [KeyPathComparator(\SleepSession.end, order: .reverse)]
    @ViewState private var selection = Set<SleepSession.ID>()
    @ViewState private var hovered: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            if history.sleepSessions.isEmpty {
                emptyState(title: "No sleeps measured yet",
                           message: "Citrus Battery measures each sleep of \(minimumMinutes) minutes or more on "
                               + "battery. Shorter ones are too brief for the battery gauge to show the loss.")
            } else if sessions.isEmpty {
                emptyState(title: "No sleeps in this period",
                           message: "Choose a longer period to see earlier sleeps.")
            } else {
                summary(SleepStats(sessions))
                    .padding(16)
                HStack(alignment: .top, spacing: 16) {
                    chart
                    wakeReasons
                        .frame(width: 270)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(height: 200)
                Divider()
                table
            }
        }
        .navigationTitle("Sleep")
    }

    private var minimumMinutes: Int { Int(SleepSession.minimumDuration / 60) }

    /// The sleeps in the chosen period, newest first.
    private var sessions: [SleepSession] {
        period.sessions(history.sleepSessions, from: from, to: to, now: Date())
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Period", selection: $period) {
                ForEach(SleepPeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if period == .custom {
                HStack(spacing: 16) {
                    DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                    DatePicker("To", selection: $to, in: from...Date(), displayedComponents: .date)
                }
                .fixedSize()
                .datePickerStyle(.compact)
            }
        }
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Summary

    private func summary(_ stats: SleepStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatTile(title: "Average Drain", value: stats.lossPerHour.map { percent($0) + " an hour" } ?? "—",
                         detail: "over \(duration(stats.hours)) asleep")
                StatTile(title: "Per Sleep", value: stats.lossPerSleep.map(percent) ?? "—",
                         detail: stats.count == 1 ? "1 sleep" : "\(stats.count) sleeps")
                StatTile(title: "Total Lost", value: percent(stats.lossFraction),
                         detail: "of a full charge")
                StatTile(title: "Brief Wakes", value: stats.briefWakesPerHour.map {
                    String(format: "%.1f an hour", $0)
                } ?? "—", detail: stats.briefWakesPerHour == nil ? "not counted for these sleeps" : "with the screen off")
            }
            if stats.highLossCount > 0 {
                AdviceBox(advice: BatteryAdvice(level: .caution, message: highLossMessage(stats.highLossCount)))
            }
        }
    }

    private func highLossMessage(_ count: Int) -> String {
        let sleeps = count == 1 ? "1 sleep" : "\(count) sleeps"
        return "\(sleeps) used more than \(percent(SleepDrain.highLossPerHour)) an hour, which is high for "
            + "Apple silicon. Apps, connected accessories or Wake for network access (Battery settings › "
            + "Options) can keep waking the Mac."
    }

    // MARK: Chart

    /// Drain per hour for each sleep, with the high-drain level marked.
    private var chart: some View {
        let points = sessions.reversed()
        let barWidth: CGFloat = points.count > 60 ? 2 : points.count > 20 ? 5 : 10
        let hoveredSession = hovered.flatMap(nearestSession)
        // Room either side so the first and last bars aren't cut in half.
        let first = points.first?.end ?? Date(), last = points.last?.end ?? Date()
        let padding = max(last.timeIntervalSince(first) * 0.03, 6 * 3600)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Drain per Hour")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(points) { session in
                    BarMark(x: .value("Woke", session.end), y: .value("Drain", session.lossPerHour * 100),
                            width: .fixed(barWidth))
                        .foregroundStyle(session.isHighLoss ? Color.orange : Color.accentColor)
                        .cornerRadius(2)
                        .opacity(hoveredSession == nil || hoveredSession?.id == session.id ? 1 : 0.4)
                }
                RuleMark(y: .value("High", SleepDrain.highLossPerHour * 100))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("High: \(percent(SleepDrain.highLossPerHour)) an hour")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                if #available(macOS 14, *), let hoveredSession {
                    RuleMark(x: .value("Woke", hoveredSession.end))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(hoveredSession)
                        }
                }
            }
            .chartXScale(domain: first.addingTimeInterval(-padding)...last.addingTimeInterval(padding))
            .chartXAxis {
                // One label per day, week or month, so a date never repeats.
                AxisMarks(values: .stride(by: axisStep(span: last.timeIntervalSince(first)))) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYScale(domain: 0...max(points.map { $0.lossPerHour * 100 }.max() ?? 0, 1.5) * 1.15)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(String(format: "%.1f%%", value.as(Double.self) ?? 0)) }
                }
            }
            .hoverable($hovered)
            HStack(spacing: 14) {
                legendItem(.accentColor, "Drain per hour")
                if points.contains(where: \.isHighLoss) { legendItem(.orange, "Higher than usual") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func axisStep(span: TimeInterval) -> Calendar.Component {
        switch span / 86_400 {
        case ..<14: .day
        case ..<120: .weekOfYear
        default: .month
        }
    }

    private func nearestSession(to date: Date) -> SleepSession? {
        sessions.min { abs($0.end.timeIntervalSince(date)) < abs($1.end.timeIntervalSince(date)) }
    }

    private func tooltip(_ session: SleepSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sleptText(session)).font(.caption.weight(.semibold))
            Text(SleepDrain.summary(session))
            if let wakes = session.briefWakes {
                Text(wakes == 1 ? "Woke briefly once" : "Woke briefly \(wakes) times")
            }
            if session.wakesLogged,
               let top = WakeBreakdown(WakeBreakdown.wakes(history.darkWakes, during: [session])).reasons.first {
                Text("Mostly \(top.reason.label.lowercased()) (\(top.count))")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    // MARK: Wake reasons

    /// Why macOS woke the Mac during the period's sleeps, from its power log.
    private var wakeReasons: some View {
        let logged = sessions.filter(\.wakesLogged)
        let breakdown = WakeBreakdown(WakeBreakdown.wakes(history.darkWakes, during: logged))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Why It Woke")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if breakdown.total == 0 {
                Text(logged.isEmpty
                    ? "Reasons are read from macOS's power log, which keeps about a week, so they're "
                        + "available for sleeps from the last week onwards."
                    : "No brief wakes in these sleeps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(breakdown.reasons, id: \.reason) { item in
                    ReasonRow(label: item.reason.label, count: item.count,
                              fraction: Double(item.count) / Double(breakdown.total))
                        .help(item.reason.explanation)
                }
                if !breakdown.tasks.isEmpty {
                    Text("Most Scheduled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(breakdown.tasks.prefix(3), id: \.name) { task in
                        HStack {
                            Text(task.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(task.name)
                            Spacer(minLength: 8)
                            Text("\(task.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                if logged.count < sessions.count {
                    Text("For \(logged.count) of \(sessions.count) sleeps: macOS's power log keeps about a week.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func legendItem(_ colour: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 10, height: 10)
            Text(title)
        }
    }

    // MARK: Table

    private var table: some View {
        Table(sessions.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Slept", value: \.end) { session in
                Text(sleptText(session))
            }
            .width(min: 170)
            TableColumn("Duration", value: \.hours) { session in
                Text(duration(session.hours)).monospacedDigit()
            }
            .width(80)
            TableColumn("Lost", value: \.lossFraction) { session in
                Text(percent(session.lossFraction)).monospacedDigit()
            }
            .width(50)
            TableColumn("Per Hour", value: \.lossPerHour) { session in
                HStack(spacing: 4) {
                    Text(percent(session.lossPerHour)).monospacedDigit()
                    if session.isHighLoss {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Higher than usual")
                    }
                }
            }
            .width(80)
            TableColumn("Brief Wakes", value: \.briefWakesSortKey) { session in
                Text(session.briefWakes.map(String.init) ?? "—").monospacedDigit()
            }
            .width(80)
        }
    }

    /// "Fri 23 Oct, 22:40 – 07:12".
    private func sleptText(_ session: SleepSession) -> String {
        session.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            + " – " + session.end.formatted(date: .omitted, time: .shortened)
    }

    /// "8 h 13 min", or whole hours from 10 hours, where minutes add nothing.
    private func duration(_ hours: Double) -> String {
        let minutes = hours >= 10 ? Int(hours.rounded()) * 60 : Int((hours * 60).rounded())
        return DurationFormat.readable(minutes)
    }

    /// "0.4%", with a decimal below 10% so small sleep losses don't all read "0%".
    private func percent(_ fraction: Double) -> String {
        String(format: fraction < 0.1 ? "%.1f%%" : "%.0f%%", fraction * 100)
    }
}

/// A wake reason with its count and a bar for its share.
private struct ReasonRow: View {
    let label: String
    let count: Int
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(count) · \(Int((fraction * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
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

/// A headline figure with a caption, for the top of a statistics page.
private struct StatTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension SleepSession {
    /// Uncounted sorts before none.
    var briefWakesSortKey: Int { briefWakes ?? -1 }
}

private extension View {
    /// Hover to inspect a sleep; needs macOS 14.
    @ViewBuilder
    func hoverable(_ selection: Binding<Date?>) -> some View {
        if #available(macOS 14, *) {
            chartXSelection(value: selection)
        } else {
            self
        }
    }
}
