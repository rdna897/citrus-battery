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
    @ViewState private var sortOrder = [KeyPathComparator(\SleepSession.start, order: .reverse)]
    @ViewState private var selection = Set<SleepSession.ID>()
    @ViewState private var hovered: Date?
    /// Where the pointer last was over the chart. Clicking clears `hovered`
    /// before the tap arrives, so taps use this.
    @ViewState private var pointed: Date?

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
                chart
                    .padding(.horizontal, 16)
                    .frame(height: 190)
                wakeReasons
                    .padding(16)
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

    /// The sleeps picked in the chart or table, if they're in the period.
    private var selectedSessions: [SleepSession] {
        sessions.filter { selection.contains($0.id) }
    }

    /// Clicking a bar picks its sleep; clicking it again shows the whole period.
    private func select(_ session: SleepSession?) {
        guard let session else { return }
        selection = selection == [session.id] ? [] : [session.id]
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
        // Picked and hovered sleeps stand out; the rest fade while there are any.
        let emphasised = Set(selectedSessions.map(\.id) + [hoveredSession?.id].compactMap { $0 })
        // Room either side so the first and last bars aren't cut in half.
        let first = points.first?.end ?? Date(), last = points.last?.end ?? Date()
        let padding = max(last.timeIntervalSince(first) * 0.03, 6 * 3600)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Drain per Hour")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(points) { session in
                    BarMark(x: .value("Woke", session.end, unit: .minute), y: .value("Drain", session.lossPerHour * 100),
                            width: .fixed(barWidth))
                        .foregroundStyle(session.isHighLoss ? Color.orange : Color.accentColor)
                        .cornerRadius(2)
                        .opacity(emphasised.isEmpty || emphasised.contains(session.id) ? 1 : 0.35)
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
                    AxisValueLabel(format: SleepDateFormat.axis(withYear: showsYear))
                }
            }
            .chartYScale(domain: 0...max(points.map { $0.lossPerHour * 100 }.max() ?? 0, 1.5) * 1.15)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(String(format: "%.1f%%", value.as(Double.self) ?? 0)) }
                }
            }
            .hoverable(Binding(get: { hovered }, set: {
                hovered = $0
                if let date = $0 { pointed = date }
            }))
            .onTapGesture { select(pointed.flatMap(nearestSession)) }
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
                Text("Main reason: \(top.reason.label) (\(top.count))")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    // MARK: Wake reasons

    /// Why macOS woke the Mac during the picked sleeps, or else the period's,
    /// from its power log.
    private var wakeReasons: some View {
        let picked = selectedSessions
        let scope = picked.isEmpty ? sessions : picked
        let logged = scope.filter(\.wakesLogged)
        let breakdown = WakeBreakdown(WakeBreakdown.wakes(history.darkWakes, during: logged))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Why It Woke")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !picked.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(picked.count == 1 ? sleptText(picked[0]) : "\(picked.count) sleeps")
                        .font(.caption.weight(.semibold))
                    Button {
                        selection = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show the whole period")
                }
            }
            if breakdown.total == 0 {
                Text(noReasonsMessage(logged: logged.count, of: scope.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ReasonBar(breakdown: breakdown)
                    .frame(height: 8)
                // One row when it fits, otherwise a column.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { reasonLegend(breakdown) }
                    VStack(alignment: .leading, spacing: 4) { reasonLegend(breakdown) }
                }
                .font(.caption)
                if !breakdown.tasks.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Most scheduled")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(breakdown.tasks.prefix(3), id: \.name) { task in
                                HStack(spacing: 6) {
                                    Text(task.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(task.name)
                                    Text("\(task.count)").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .font(.caption)
                }
                if logged.count < scope.count {
                    Text("For \(logged.count) of \(scope.count) sleeps: macOS's power log keeps about a week.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reasonLegend(_ breakdown: WakeBreakdown) -> some View {
        ForEach(breakdown.reasons, id: \.reason) { item in
            HStack(spacing: 5) {
                Circle().fill(item.reason.colour).frame(width: 8, height: 8)
                Text(item.reason.label)
                Text("\(item.count) · \(Int((Double(item.count) / Double(breakdown.total) * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .help(item.reason.explanation)
        }
    }

    private func noReasonsMessage(logged: Int, of count: Int) -> String {
        if logged > 0 { return count == 1 ? "No brief wakes in this sleep." : "No brief wakes in these sleeps." }
        if !selectedSessions.isEmpty {
            return (count == 1 ? "This sleep is" : "These sleeps are")
                + " older than macOS's power log, which keeps about a week."
        }
        return "Reasons are read from macOS's power log, which keeps about a week, so they're "
            + "available for sleeps from the last week onwards."
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
            TableColumn("Slept", value: \.start) { session in
                DateTimeCell(date: session.start, withYear: showsYear)
            }
            .width(min: showsYear ? 140 : 130)
            TableColumn("Woke", value: \.end) { session in
                // The time alone on the day it slept; with the date when it woke on a later day.
                DateTimeCell(date: session.end, withYear: showsYear, showsDate: !Calendar.current.isDate(session.end,
                                                                                   inSameDayAs: session.start))
            }
            .width(min: showsYear ? 140 : 130)
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
        .onExitCommand { selection = [] }
    }

    /// Dates show the year once any sleep in the period is from another year,
    /// on every row so the columns stay aligned.
    private var showsYear: Bool {
        sessions.contains { !Calendar.current.isDate($0.start, equalTo: Date(), toGranularity: .year) }
    }

    /// "Fri 23 Oct, 13:33 – 14:08", or "Fri 23 Oct, 22:40 – Sat 24 Oct, 07:12"
    /// when it woke on a later day.
    private func sleptText(_ session: SleepSession) -> String {
        let end = Calendar.current.isDate(session.end, inSameDayAs: session.start)
            ? session.end.formatted(SleepDateFormat.time)
            : session.end.formatted(SleepDateFormat.day(withYear: showsYear)) + ", "
                + session.end.formatted(SleepDateFormat.time)
        return session.start.formatted(SleepDateFormat.day(withYear: showsYear)) + ", "
            + session.start.formatted(SleepDateFormat.time)
            + " – " + end
    }

    /// "8 h 13 min"; whole hours from 10 hours, where minutes add nothing;
    /// days and hours from a day, such as "2 d 3 h".
    private func duration(_ hours: Double) -> String {
        if hours >= 24 {
            let total = Int(hours.rounded())
            return total % 24 == 0 ? "\(total / 24) d" : "\(total / 24) d \(total % 24) h"
        }
        let minutes = hours >= 10 ? Int(hours.rounded()) * 60 : Int((hours * 60).rounded())
        return DurationFormat.readable(minutes)
    }

    /// "0.4%", with a decimal below 10% so small sleep losses don't all read "0%".
    private func percent(_ fraction: Double) -> String {
        String(format: fraction < 0.1 ? "%.1f%%" : "%.0f%%", fraction * 100)
    }
}

private enum SleepDateFormat {
    /// "Sat 24 Oct", or "24 Oct 2025" with the year, where the weekday matters less
    /// and would make the column too wide.
    static func day(withYear: Bool) -> Date.FormatStyle {
        withYear ? .dateTime.day().month(.abbreviated).year()
            : .dateTime.weekday(.abbreviated).day().month(.abbreviated)
    }

    /// "24 Oct", or "24 Oct 2026".
    static func axis(withYear: Bool) -> Date.FormatStyle {
        let day = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return withYear ? day.year() : day
    }
    /// "09:35", with a leading zero so times line up.
    static let time = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)
}

/// A date and time in a table cell, with the date in a fixed-width slot so
/// the times line up down the column.
private struct DateTimeCell: View {
    let date: Date
    var withYear = false
    var showsDate = true

    var body: some View {
        HStack(spacing: 8) {
            Text(showsDate ? date.formatted(SleepDateFormat.day(withYear: withYear)) : "")
                .frame(minWidth: withYear ? 92 : 82, alignment: .leading)
            Text(date.formatted(SleepDateFormat.time))
        }
        .monospacedDigit()
    }
}

/// Each wake reason's share, as one bar split by colour.
private struct ReasonBar: View {
    let breakdown: WakeBreakdown

    var body: some View {
        GeometryReader { geometry in
            let gaps = CGFloat(breakdown.reasons.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(breakdown.reasons, id: \.reason) { item in
                    Rectangle()
                        .fill(item.reason.colour)
                        .frame(width: max((geometry.size.width - gaps) * Double(item.count)
                            / Double(breakdown.total), 3))
                }
            }
            .clipShape(Capsule())
        }
    }
}

private extension WakeReason {
    /// Orange is left for high drain in the chart.
    var colour: Color {
        switch self {
        case .wireless: .blue
        case .scheduledTask: .purple
        case .networkUpkeep: .teal
        case .power: .green
        case .other: .gray
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
