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
    @AppStorage(PreferenceKey.powerChartPeriod) private var period = PowerPeriod.live
    @ViewState private var selection: Date?

    private static let sleepColour = Color.indigo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Period", selection: $period) {
                    ForEach(PowerPeriod.allCases) { Text($0.label).tag($0) }
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
        .onChange(of: period) { _ in selection = nil }
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
            }
            .chartXAxis { timeAxis(labelled: true, domain: liveDomain) }
            .chartYAxisLabel("W")
            .timeAxisTitle(period.axisTitle)
            .frame(height: 140)
        } else {
            placeholder("Collecting readings…")
        }
    }

    // MARK: History

    @ViewBuilder
    private func historyCharts(now: Date) -> some View {
        let points = PowerTimeline.points(minutes, period: period, now: now)
        let sleeps = PowerTimeline.sleeps(sleeps, period: period, now: now)
        let domain = now.addingTimeInterval(-period.duration)...now
        // With the charge strip, the time labels go once, under it.
        let hasCharge = points.contains { $0.chargePercent != nil }
        if points.isEmpty && sleeps.isEmpty {
            placeholder("No readings in the last \(period.label) yet. Citrus Battery records power "
                + "while it's running and keeps 30 days.")
        } else {
            readout(points: points, sleeps: sleeps)
            Chart {
                sleepBands(sleeps, labelled: true, domain: domain)
                ForEach(points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Watts", point.averageWatts),
                             series: .value("Segment", point.segment), stacking: .unstacked)
                        .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.25), .clear],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.date), y: .value("Watts", point.averageWatts),
                             series: .value("Segment", point.segment))
                        .foregroundStyle(Color.accentColor)
                }
                if let selection {
                    RuleMark(x: .value("Selected", selection))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: domain)
            .chartXAxis { timeAxis(labelled: !hasCharge, domain: domain) }
            .chartYAxis { valueAxis(values: .automatic(desiredCount: 4)) { "\($0)" } }
            .chartYAxisLabel("W")
            .timeAxisTitle(hasCharge ? nil : period.axisTitle)
            .selectable($selection)
            .frame(height: hasCharge ? 110 : 150)
            .padding(.bottom, hasCharge ? 10 : 0)

            if hasCharge {
                Chart {
                    sleepBands(sleeps, labelled: false, domain: domain)
                    ForEach(points.filter { $0.chargePercent != nil }) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Charge", point.chargePercent ?? 0),
                                 series: .value("Segment", point.segment))
                            .foregroundStyle(.green)
                    }
                    if let selection {
                        RuleMark(x: .value("Selected", selection))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartXScale(domain: domain)
                .chartXAxis { timeAxis(labelled: true, domain: domain) }
                .chartYScale(domain: 0...100)
                .chartYAxis { valueAxis(values: .stride(by: 50)) { "\($0)%" } }
                .timeAxisTitle(period.axisTitle)
                .selectable($selection)
                .frame(height: 95)
            }
            legend(hasSleep: !sleeps.isEmpty)
        }
    }

    /// Shaded spans for the times the Mac slept, labelled when there's room.
    @ChartContentBuilder
    private func sleepBands(_ sleeps: [DateInterval], labelled: Bool,
                            domain: ClosedRange<Date>) -> some ChartContent {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        ForEach(sleeps, id: \.start) { sleep in
            RectangleMark(xStart: .value("Asleep from", sleep.start), xEnd: .value("Asleep until", sleep.end))
                .foregroundStyle(Self.sleepColour.opacity(0.14))
                .annotation(position: .overlay, alignment: .top) {
                    if labelled {
                        let share = sleep.duration / span
                        if share >= 0.12 {
                            Label("Asleep", systemImage: "moon.zzz.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Self.sleepColour)
                                .padding(.top, 4)
                        } else if share >= 0.03 {
                            Image(systemName: "moon.zzz.fill")
                                .font(.caption2)
                                .foregroundStyle(Self.sleepColour)
                                .padding(.top, 4)
                        }
                    }
                }
        }
    }

    /// Fixed-width labels, so the power and charge charts' plot areas line up.
    private func valueAxis(values: AxisMarkValues, label: @escaping (Int) -> String) -> some AxisContent {
        AxisMarks(position: .trailing, values: values) { value in
            AxisGridLine()
            AxisValueLabel {
                Text(label(value.as(Int.self) ?? 0))
                    .frame(width: 34, alignment: .leading)
            }
        }
    }

    private var liveDomain: ClosedRange<Date> {
        (live.first?.date ?? Date())...(live.last?.date ?? Date())
    }

    private func timeAxis(labelled: Bool, domain: ClosedRange<Date>) -> some AxisContent {
        AxisMarks(values: PowerTimeline.ticks(period: period, domain: domain)) { _ in
            AxisGridLine()
            if labelled {
                switch period {
                case .live:
                    AxisValueLabel(format: .dateTime.hour().minute().second(), anchor: .top)
                case .hour, .day:
                    AxisValueLabel(format: .dateTime.hour().minute(), anchor: .top)
                case .week:
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), anchor: .top)
                case .month:
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), anchor: .top)
                }
            }
        }
    }

    /// The hovered moment, or a summary of the period.
    private func readout(points: [PowerPoint], sleeps: [DateInterval]) -> some View {
        let text: String
        if let selection, let sleep = sleeps.first(where: { $0.contains(selection) }) {
            text = "Asleep \(range(sleep)) (\(DurationFormat.readable(Int(sleep.duration / 60))))"
        } else if let selection, let point = nearest(to: selection, in: points) {
            var parts = [timeText(point.date),
                         String(format: "%.1f W average, %.1f W peak", point.averageWatts, point.peakWatts)]
            if let charge = point.chargePercent { parts.append("\(charge)% charged") }
            text = parts.joined(separator: " · ")
        } else {
            let average = points.map(\.averageWatts).reduce(0, +) / Double(max(points.count, 1))
            var parts = [String(format: "Average %.1f W", average)]
            if let peak = points.map(\.peakWatts).max() { parts.append(String(format: "peak %.1f W", peak)) }
            let slept = sleeps.map(\.duration).reduce(0, +)
            if slept >= 60 {
                // Whole hours are precise enough once sleeps add up.
                let minutes = slept >= 10 * 3600 ? Int((slept / 3600).rounded()) * 60 : Int(slept / 60)
                parts.append("asleep \(DurationFormat.readable(minutes))")
            }
            text = parts.joined(separator: " · ")
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func legend(hasSleep: Bool) -> some View {
        HStack(spacing: 14) {
            legendItem(Color.accentColor, "System power")
            if minutes.contains(where: { $0.chargePercent != nil }) {
                legendItem(.green, "Charge")
            }
            if hasSleep {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.sleepColour.opacity(0.25))
                        .frame(width: 12, height: 10)
                    Text("Mac asleep")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ colour: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(colour).frame(width: 12, height: 3)
            Text(title)
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 110)
    }

    private func nearest(to date: Date, in points: [PowerPoint]) -> PowerPoint? {
        guard let point = points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(point.date.timeIntervalSince(date)) <= period.bucket
        else { return nil }
        return point
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
