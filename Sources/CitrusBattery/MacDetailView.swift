import Charts
import CitrusKit
import SwiftUI

struct MacDetailView: View {
    var body: some View {
        ScrollView {
            MacDetailContent()
        }
        .navigationTitle("This Mac")
    }
}

/// The detail cards, separate from the scroll view so they can also be rendered offscreen.
struct MacDetailContent: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.capacityUnit) private var capacityUnit = CapacityUnit.milliampHours
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.raw

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let battery = monitor.battery {
                batterySection(battery)
                powerSection(battery)
                if !battery.failures.messages.isEmpty {
                    failuresSection(battery.failures)
                }
                if let lifetime = battery.lifetime {
                    LifetimeCard(lifetime: lifetime, cyclesSinceCalibration: battery.cyclesSinceCalibration)
                }
                detailsSection(battery)
            } else {
                noBattery
                powerSection(nil)
            }
        }
        .padding(20)
        .frame(maxWidth: 720, alignment: .leading)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.marketingName ?? "Mac")
                    .font(.title2.weight(.semibold))
                Text([monitor.macInfo.modelIdentifier, monitor.macInfo.modelNumber, monitor.macInfo.chip]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text(monitor.macInfo.osVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func batterySection(_ battery: MacBatterySnapshot) -> some View {
        Card(title: "Battery", systemImage: "battery.100percent") {
            VStack(alignment: .leading, spacing: 14) {
                MeterRow(
                    title: "Current charge",
                    fraction: battery.chargeFraction(style: capacityStyle),
                    detail: capacityText(battery.currentCapacity, battery),
                    tint: .accentColor
                )
                MeterRow(
                    title: "Battery health",
                    fraction: battery.healthFraction,
                    detail: capacityText(battery.fullChargeCapacity, battery).map { "\($0) of " }
                        .map { $0 + (capacityText(battery.designCapacity, battery) ?? "—") },
                    tint: healthColor(battery.healthFraction)
                )
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    InfoRow("Status", statusText(battery))
                    InfoRow(battery.isCharging ? "Time until full" : "Time until empty",
                            battery.timeRemainingMinutes.map(DurationFormat.readable))
                    InfoRow("Charge cycles", cyclesText(battery))
                    InfoRow("Temperature", battery.temperatureCelsius.map(temperatureUnit.format(celsius:)))
                    if let limit = monitor.chargeLimit {
                        InfoRow("Charge limit", chargeLimitText(limit), hidesWhenEmpty: true)
                        InfoRow("Optimized charging", optimizedChargingText(limit), hidesWhenEmpty: true)
                    }
                    InfoRow("macOS health", battery.powerSource?.healthDescription, hidesWhenEmpty: true)
                }
                if let advice = monitor.chargeLimit?.advice(cyclesSinceCalibration: battery.cyclesSinceCalibration) {
                    AdviceBox(advice: advice)
                }
            }
        }
    }

    private func powerSection(_ battery: MacBatterySnapshot?) -> some View {
        Card(title: "Power", systemImage: "bolt.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    InfoRow("System usage", watts(monitor.displayedSystemWatts))
                    InfoRow("Max usage (1 min)", watts(monitor.maxSystemWattsLastMinute))
                    if let battery {
                        InfoRow(batteryFlowTitle(battery), watts(battery.batteryPowerWatts.map(abs)))
                    }
                    InfoRow("From adapter", watts(monitor.power.adapterWatts))
                    InfoRow("Charger", battery?.adapter.flatMap(adapterText), hidesWhenEmpty: true)
                    InfoRow("CPU temperature", monitor.power.cpuTemperatureCelsius.map(temperatureUnit.format(celsius:)))
                }
                if monitor.powerHistory.count > 1 {
                    Chart(monitor.powerHistory) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("Watts", sample.systemWatts))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Time", sample.date), y: .value("Watts", sample.systemWatts))
                            .foregroundStyle(.linearGradient(
                                colors: [Color.accentColor.opacity(0.25), .clear],
                                startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    .chartYAxisLabel("W")
                    .chartXAxis(.hidden)
                    .frame(height: 110)
                }
            }
        }
    }

    private func failuresSection(_ failures: BatteryFailure) -> some View {
        Card(title: "Battery failures", systemImage: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(failures.messages, id: \.self) { message in
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func detailsSection(_ battery: MacBatterySnapshot) -> some View {
        Card(title: "Details", systemImage: "info.circle.fill") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                InfoRow("Full charge capacity", capacityText(battery.fullChargeCapacity, battery))
                InfoRow("Design capacity", capacityText(battery.designCapacity, battery))
                InfoRow("Nominal capacity", capacityText(battery.nominalChargeCapacity, battery))
                InfoRow("Voltage", battery.voltageMillivolts.map { String(format: "%.2f V", Double($0) / 1000) })
                InfoRow("Amperage", battery.amperageMilliamps.map { "\($0) mA" })
                InfoRow("Battery serial", battery.serialNumber)
                InfoRow("Manufacturer", battery.manufacturer, hidesWhenEmpty: true)
                InfoRow("Manufacture date", manufactureText(battery), hidesWhenEmpty: true)
                InfoRow("Battery age", ageText(battery), hidesWhenEmpty: true)
                InfoRow("Gas gauge", battery.gasGaugeName)
                InfoRow("Mac serial", monitor.macInfo.serialNumber)
                InfoRow("Up since", monitor.macInfo.bootDate.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                })
            }
        }
    }

    private var noBattery: some View {
        Card(title: "Battery", systemImage: "battery.0percent") {
            Text("No battery found. This Mac runs on mains power only.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Formatting

    private func capacityText(_ mAh: Int?, _ battery: MacBatterySnapshot) -> String? {
        mAh.map { capacityUnit.format(milliampHours: $0, voltageMillivolts: battery.voltageMillivolts) }
    }

    private func cyclesText(_ battery: MacBatterySnapshot) -> String? {
        battery.cycleCount.map(String.init)
    }

    private func chargeLimitText(_ limit: ChargeLimitStatus) -> String? {
        var parts: [String] = []
        if let percent = limit.macOSLimitPercent { parts.append("\(percent)% (macOS)") }
        if let level = limit.smcChargeLevelLimit { parts.append("\(level)% (set in firmware)") }
        parts += limit.thirdPartyLimiters.map { "set by \($0)" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func optimizedChargingText(_ limit: ChargeLimitStatus) -> String? {
        guard limit.optimizedChargingEnabled else { return nil }
        return limit.optimizedChargingEngaged ? "On, holding charge for now" : "On"
    }

    private func statusText(_ battery: MacBatterySnapshot) -> String {
        if battery.isFullyCharged { return "Fully charged" }
        if battery.isCharging { return "Charging" }
        if battery.isExternalPowerConnected { return "On power adapter, not charging" }
        return "On battery"
    }

    private func batteryFlowTitle(_ battery: MacBatterySnapshot) -> String {
        (battery.batteryPowerWatts ?? 0) >= 0 ? "Charging with" : "Discharging with"
    }

    private func adapterText(_ adapter: PowerAdapter) -> String? {
        let text = [adapter.watts.flatMap { $0 > 0 ? "\($0) W" : nil }, adapter.name]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func watts(_ value: Double?) -> String? {
        value.map { String(format: "%.1f W", $0) }
    }

    private func manufactureText(_ battery: MacBatterySnapshot) -> String? {
        if let date = battery.manufactureDate.flatMap(dateText) { return date }
        if let estimate = battery.estimatedManufactureDate {
            let date = estimate.formatted(date: .abbreviated, time: .omitted)
            let week = battery.manufactureWeek.map { "week \($0.week), " } ?? ""
            return "\(date) (\(week)estimated from operating time)"
        }
        guard let week = battery.manufactureWeek else { return nil }
        let month = Calendar.current.monthSymbols[week.month - 1]
        return "Week \(week.week) (\(month)), year not recorded"
    }

    private func ageText(_ battery: MacBatterySnapshot) -> String? {
        let start = battery.manufactureDate.flatMap { Calendar.current.date(from: $0) }
            ?? battery.estimatedManufactureDate
        guard let start else { return nil }
        let days = Calendar.current.dateComponents([.day], from: start, to: battery.date).day ?? 0
        return "\(days) days"
    }

    private func dateText(_ components: DateComponents) -> String? {
        Calendar.current.date(from: components)?.formatted(date: .abbreviated, time: .omitted)
    }

    private func healthColor(_ fraction: Double?) -> Color {
        switch fraction ?? 1 {
        case 0.8...: .green
        case 0.6..<0.8: .yellow
        default: .red
        }
    }
}

// MARK: - Building blocks

/// Gas-gauge lifetime statistics; shared by the Mac and iPhone/iPad pages.
struct LifetimeCard: View {
    let lifetime: BatteryLifetime
    let cyclesSinceCalibration: Int?
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius

    var body: some View {
        Card(title: "Lifetime", systemImage: "heart.text.square.fill") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                InfoRow("Operating time", lifetime.totalOperatingHours.map {
                    "\($0.formatted()) h (\($0 / 24) days)"
                })
                InfoRow("Temperature range", range(lifetime.minimumTemperatureCelsius,
                                                   lifetime.maximumTemperatureCelsius,
                                                   temperatureUnit.format(celsius:)))
                InfoRow("Average temperature", lifetime.averageTemperatureCelsius.map(temperatureUnit.format(celsius:)))
                InfoRow("Pack voltage range", range(lifetime.minimumPackVoltageMillivolts.map(Double.init),
                                                    lifetime.maximumPackVoltageMillivolts.map(Double.init)) {
                    String(format: "%.2f V", $0 / 1000)
                })
                InfoRow("Max charge current", lifetime.maximumChargeCurrentMilliamps.map { "\($0) mA" })
                InfoRow("Max discharge current", lifetime.maximumDischargeCurrentMilliamps.map { "\(abs($0)) mA" })
                InfoRow("Gauge last calibrated", cyclesSinceCalibration.map {
                    $0 == 0 ? "This cycle" : "\($0) cycle\($0 == 1 ? "" : "s") ago"
                }, hidesWhenEmpty: true)
            }
        }
    }

    private func range(_ low: Double?, _ high: Double?, _ format: (Double) -> String) -> String? {
        guard let low, let high else { return nil }
        return "\(format(low)) – \(format(high))"
    }
}

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AdviceBox: View {
    let advice: ChargeLimitAdvice

    var body: some View {
        Label {
            Text(advice.message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: advice.level == .caution ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(advice.level == .caution ? Color.orange : Color.secondary)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((advice.level == .caution ? Color.orange : Color.primary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MeterRow: View {
    let title: String
    let fraction: Double?
    let detail: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(fraction.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    .font(.body.monospacedDigit().weight(.semibold))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * min(max(fraction ?? 0, 0), 1))
                }
            }
            .frame(height: 8)
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String?
    /// Omit the row entirely when there is no value (for fields many Macs lack).
    let hidesWhenEmpty: Bool

    init(_ title: String, _ value: String?, hidesWhenEmpty: Bool = false) {
        self.title = title
        self.value = value
        self.hidesWhenEmpty = hidesWhenEmpty
    }

    var body: some View {
        if value != nil || !hidesWhenEmpty {
            row
        }
    }

    private var row: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }
}
