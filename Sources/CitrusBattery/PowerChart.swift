import Charts
import CitrusKit
import SwiftUI

/// System power over a chosen period, with the times the Mac slept shaded.
struct PowerChart: View {
    /// Readings from the last two minutes, every few seconds.
    let live: [PowerSample]
    /// Saved minutes and sleeps from the last 30 days.
    let minutes: [PowerMinute]
    let sleeps: [DateInterval]
    @AppStorage(PreferenceKey.powerChartPeriod) private var chosenPeriod = PowerPeriod.live
    @ViewState private var selection: Date?
    /// What the history charts draw, kept until the readings, period or minute change.
    @ViewState private var cache = HistoryChartCache()

    private static let sleepColour = Color.indigo

    /// Longer periods appear once there are records to fill them.
    private var periods: [PowerPeriod] {
        let start = [minutes.first?.start, sleeps.first?.start].compactMap { $0 }.min()
        return PowerPeriod.available(recordedSince: start, now: Date())
    }

    /// The chosen period, or the longest offered if it isn't (yet) available.
    private var period: PowerPeriod {
        periods.contains(chosenPeriod) ? chosenPeriod : periods.last ?? .live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Period", selection: Binding(get: { period }, set: { chosenPeriod = $0 })) {
                    ForEach(periods) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Spacer()
            }
            if period == .live {
                liveChart
            } else {
                historyCharts(now: Date())
            }
        }
        .onChange(of: chosenPeriod) { _ in selection = nil }
    }

    // MARK: Live

    @ViewBuilder
    private var liveChart: some View {
        if live.count > 1 {
            Chart(live) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("Watts", sample.systemWatts))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Time", sample.date), y: .value("Watts", sample.systemWatts))
                    .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.25), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                selectionRule(labelled: true)
            }
            .chartXAxis { timeAxis(labelled: true, domain: liveDomain) }
            .chartYAxisLabel("W")
            .selectable($selection)
            .timeAxisTitle(period.axisTitle)
            .frame(height: 140)
        } else {
            placeholder("Collecting readings…")
        }
    }

    // MARK: History

    /// Battery level and power use as bars, as in macOS's Battery settings, with
    /// the Mac's sleeps on a strip underneath.
    @ViewBuilder
    private func historyCharts(now: Date) -> some View {
        // Redrawn with every live reading and pointer move; the bars only change
        // when a minute is saved or the period changes.
        let data = cache.data(period: period, minutes: minutes, sleeps: sleeps, now: now)
        let domain = data.domain
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let sleeps = data.sleeps
        let bars = data.bars
        let wakes = data.wakes
        let hasCharge = bars.contains { $0.chargePercent != nil }
        let hasCharging = bars.contains { $0.onAdapter }
        if bars.isEmpty && sleeps.isEmpty {
            placeholder("No readings in the last \(period.label) yet. Citrus Battery records power "
                + "while it's running and keeps 30 days.")
        } else {
            readout(bars: bars, sleeps: sleeps, wakes: wakes, span: span)
            if hasCharge {
                chartTitle("Battery Level")
                Chart {
                    ForEach(bars.filter(\.onAdapter)) { bar in
                        RectangleMark(xStart: .value("From", bar.start), xEnd: .value("Until", bar.end),
                                      yStart: .value("Charge", 0), yEnd: .value("Charge", 100))
                            .foregroundStyle(Color.green.opacity(0.12))
                    }
                    ForEach(bars) { bar in
                        if let charge = bar.chargePercent {
                            barMark(bar, label: "Charge", value: charge)
                                .foregroundStyle(Color.green.gradient)
                        }
                    }
                    selectionRule(labelled: true)
                }
                .chartXScale(domain: domain)
                .chartXAxis { timeAxis(labelled: false, domain: domain) }
                .chartYScale(domain: 0...100)
                .chartYAxis { valueAxis(values: .stride(by: 50)) { "\($0)%" } }
                .selectable($selection)
                .frame(height: 80)
            }
            chartTitle("Power Use")
            Chart {
                ForEach(bars) { bar in
                    if let watts = bar.watts {
                        barMark(bar, label: "Watts", value: watts)
                            .foregroundStyle(Color.accentColor.gradient)
                    }
                }
                // The time goes on the top chart: battery level, when there is one.
                selectionRule(labelled: !hasCharge)
            }
            .chartXScale(domain: domain)
            .chartXAxis { timeAxis(labelled: false, domain: domain) }
            .chartYAxis { valueAxis(values: .automatic(desiredCount: 3)) { "\($0) W" } }
            .selectable($selection)
            .frame(height: 80)
            sleepStrip(sleeps, domain: domain, title: axisTitle(domain: domain, now: now))
            legend(hasCharge: hasCharge, hasCharging: hasCharging, hasSleep: !sleeps.isEmpty)
        }
    }

    /// A bar filling most of its slot, leaving a gap to the next.
    private func barMark(_ bar: PowerBar, label: String, value: Double) -> some ChartContent {
        let inset = bar.end.timeIntervalSince(bar.start) * 0.12
        return RectangleMark(xStart: .value("From", bar.start.addingTimeInterval(inset)),
                             xEnd: .value("Until", bar.end.addingTimeInterval(-inset)),
                             yStart: .value(label, 0), yEnd: .value(label, value))
            .cornerRadius(1.5)
    }

    /// A line at the hovered moment; labelled with its time on the top chart.
    @ChartContentBuilder
    private func selectionRule(labelled: Bool = false) -> some ChartContent {
        // Hovering needs macOS 14 (see selectable), so selection is nil before it.
        if #available(macOS 14, *), let selection {
            if labelled {
                rule(at: selection)
                    .annotation(position: .top, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(selectionText(selection))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            // Opaque, like a tooltip, as it can cover the chart's title.
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator))
                    }
            } else {
                rule(at: selection)
            }
        }
    }

    private func rule(at date: Date) -> some ChartContent {
        RuleMark(x: .value("Selected", date))
            .foregroundStyle(.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    /// The exact hovered time, with the date once the period spans days; on the
    /// live chart, also the power at that moment.
    private func selectionText(_ date: Date) -> String {
        switch period {
        case .live:
            let time = date.formatted(.dateTime.hour().minute().second())
            guard let sample = live.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
            else { return time }
            return time + String(format: " · %.1f W", sample.systemWatts)
        case .hour:
            return date.formatted(date: .omitted, time: .shortened)
        case .day:
            return Calendar.current.isDateInToday(date)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .week, .month:
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        }
    }

    private func chartTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    /// The Mac's sleeps on a thin strip, with the time labels under it. Brief
    /// wakes show as small power bars, and in the readout when hovering a sleep.
    private func sleepStrip(_ sleeps: [DateInterval], domain: ClosedRange<Date>, title: String) -> some View {
        Chart {
            RectangleMark(xStart: .value("From", domain.lowerBound), xEnd: .value("Until", domain.upperBound),
                          yStart: .value("Lane", 0.25), yEnd: .value("Lane", 0.75))
                .foregroundStyle(Color.primary.opacity(0.06))
            ForEach(sleeps, id: \.start) { sleep in
                RectangleMark(xStart: .value("Asleep from", sleep.start), xEnd: .value("Asleep until", sleep.end),
                              yStart: .value("Lane", 0.25), yEnd: .value("Lane", 0.75))
                    .foregroundStyle(Self.sleepColour.opacity(0.75))
                    .cornerRadius(2)
            }
            selectionRule()
        }
        .chartXScale(domain: domain)
        .chartXAxis { timeAxis(labelled: true, domain: domain) }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            // An empty label as wide as the others keeps the plot areas aligned.
            AxisMarks(position: .trailing, values: [0.5]) { _ in
                AxisValueLabel(horizontalSpacing: 8) { Text("").frame(width: 34) }
            }
        }
        .timeAxisTitle(title)
        .selectable($selection)
        .frame(height: 64)
    }

    /// Fixed-width labels, so the power and charge charts' plot areas line up.
    private func valueAxis(values: AxisMarkValues, label: @escaping (Int) -> String) -> some AxisContent {
        AxisMarks(position: .trailing, values: values) { value in
            AxisGridLine()
            AxisValueLabel(horizontalSpacing: 8) {
                Text(label(value.as(Int.self) ?? 0))
                    .frame(width: 34, alignment: .leading)
            }
        }
    }

    private var liveDomain: ClosedRange<Date> {
        (live.first?.date ?? Date())...(live.last?.date ?? Date())
    }

    private func timeAxis(labelled: Bool, domain: ClosedRange<Date>) -> some AxisContent {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let step = PowerTimeline.tickStep(span: span)
        return AxisMarks(values: PowerTimeline.ticks(domain: domain)) { _ in
            AxisGridLine()
            if labelled {
                if step < 60 {
                    AxisValueLabel(format: .dateTime.hour().minute().second(), anchor: .top)
                } else if step < 86_400 {
                    AxisValueLabel(format: .dateTime.hour().minute(), anchor: .top)
                } else if step == 86_400 && span <= 7 * 86_400 {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), anchor: .top)
                } else {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), anchor: .top)
                }
            }
        }
    }

    /// "Last 24 hours", or when readings start later, when they start.
    private func axisTitle(domain: ClosedRange<Date>, now: Date) -> String {
        let start = domain.lowerBound
        guard now.timeIntervalSince(start) < period.duration - 60 else { return period.axisTitle }
        let text = Calendar.current.isDate(start, inSameDayAs: now)
            ? start.formatted(date: .omitted, time: .shortened)
            : start.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return "Since \(text), when recording began"
    }

    /// The hovered moment, or a summary of the period.
    private func readout(bars: [PowerBar], sleeps: [DateInterval], wakes: [BriefWake],
                         span: TimeInterval) -> some View {
        let text: String
        if let selection, let sleep = sleeps.first(where: { $0.contains(selection) }) {
            let woke = wakes.filter { sleep.contains($0.middle) }.count
            text = "Asleep \(range(sleep)) (\(DurationFormat.readable(Int(sleep.duration / 60))))"
                + (woke > 0 ? ", woke briefly \(timesText(woke)) with the screen off" : "")
        } else if let selection, let bar = bars.first(where: { $0.start <= selection && selection < $0.end }) {
            var parts = [bar.end.timeIntervalSince(bar.start) > 60
                ? "\(timeText(bar.start))–\(bar.end.formatted(date: .omitted, time: .shortened))"
                : timeText(bar.start)]
            if let watts = bar.watts { parts.append(String(format: "%.1f W average", watts)) }
            if let charge = bar.chargePercent { parts.append("\(Int(charge.rounded()))% charged") }
            if bar.onAdapter { parts.append("on power adapter") }
            text = parts.joined(separator: " · ")
        } else {
            let summary = cache.summary
            var parts = [String(format: "Average %.1f W while awake", summary.average)]
            if let peak = summary.peak { parts.append(String(format: "peak %.1f W", peak)) }
            let slept = sleeps.map(\.duration).reduce(0, +)
            if slept >= 60 {
                // Whole hours are precise enough once sleeps add up.
                let minutes = slept >= 10 * 3600 ? Int((slept / 3600).rounded()) * 60 : Int(slept / 60)
                parts.append("asleep \(DurationFormat.readable(minutes))"
                    + (wakes.isEmpty ? "" : " (woke briefly \(timesText(wakes.count)))"))
            }
            text = parts.joined(separator: " · ")
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func legend(hasCharge: Bool, hasCharging: Bool, hasSleep: Bool) -> some View {
        HStack(spacing: 14) {
            if hasCharge { legendItem(.green, "Battery level") }
            if hasCharging { legendItem(.green.opacity(0.2), "On power adapter") }
            legendItem(Color.accentColor, "Power use")
            if hasSleep { legendItem(Self.sleepColour.opacity(0.75), "Asleep") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func legendItem(_ colour: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 10, height: 10)
            Text(title)
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 110)
    }

    private func timesText(_ count: Int) -> String {
        count == 1 ? "once" : count == 2 ? "twice" : "\(count) times"
    }

    private func timeText(_ date: Date) -> String {
        period == .hour || period == .day && Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    private func range(_ interval: DateInterval) -> String {
        "\(timeText(interval.start)) – \(interval.end.formatted(date: .omitted, time: .shortened))"
    }
}

private extension View {
    /// The time axis title, centred under the chart.
    @ViewBuilder
    func timeAxisTitle(_ title: String?) -> some View {
        if let title {
            chartXAxisLabel(position: .bottom, alignment: .center) {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            self
        }
    }

    /// Hover to inspect a moment; needs macOS 14.
    @ViewBuilder
    func selectable(_ selection: Binding<Date?>) -> some View {
        if #available(macOS 14, *) {
            chartXSelection(value: selection)
        } else {
            self
        }
    }
}

/// The history charts' bars, sleeps and wakes, worked out once per change of
/// readings, period or minute rather than on every redraw. Not observed: it
/// only saves work for the view that owns it.
@MainActor
final class HistoryChartCache {
    struct Data {
        var domain: ClosedRange<Date>
        var sleeps: [DateInterval]
        var bars: [PowerBar]
        var wakes: [BriefWake]
    }

    private struct Key: Equatable {
        var period: PowerPeriod
        var minuteCount: Int
        var lastMinute: Date?
        var sleepCount: Int
        var lastSleepEnd: Date?
        var minute: Int
    }

    private var key: Key?
    private var cached: Data?
    /// Average and peak power over the bars' minutes, for the readout.
    private(set) var summary: (average: Double, peak: Double?) = (0, nil)

    func data(period: PowerPeriod, minutes: [PowerMinute], sleeps: [DateInterval], now: Date) -> Data {
        let key = Key(period: period, minuteCount: minutes.count, lastMinute: minutes.last?.start,
                      sleepCount: sleeps.count, lastSleepEnd: sleeps.last?.end,
                      minute: Int(now.timeIntervalSince1970 / 60))
        if key == self.key, let cached { return cached }
        let domain = PowerTimeline.domain(period: period, minutes: minutes, sleeps: sleeps, now: now)
        let inDomain = PowerTimeline.sleeps(sleeps, in: domain)
        let bars = PowerTimeline.bars(minutes, in: domain, sleeps: sleeps)
        let data = Data(domain: domain, sleeps: inDomain, bars: bars,
                        wakes: PowerTimeline.briefWakes(minutes, sleeps: inDomain))
        // Every recorded minute in the domain makes a bar, so the bars' span holds
        // exactly the minutes they show.
        let span = (bars.first?.start ?? .distantFuture)..<(bars.last?.end ?? .distantPast)
        let recorded = span.isEmpty ? [] : minutes.filter { span.contains($0.start) }
        summary = (recorded.map(\.averageWatts).reduce(0, +) / Double(max(recorded.count, 1)),
                   recorded.map(\.peakWatts).max())
        self.key = key
        cached = data
        return data
    }
}
