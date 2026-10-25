import Charts
import CitrusKit
import SwiftUI

struct MacDetailView: View {
    @EnvironmentObject private var history: HistoryController
    @StateObject private var sleepBlockers = SleepBlockerMonitor()

    var body: some View {
        ScrollView {
            MacDetailContent(trend: history.thisMacSerial.flatMap { history.trends[$0] },
                             sleepSessions: history.sleepSessions,
                             powerMinutes: history.powerMinutes, sleepPeriods: history.sleepPeriods,
                             sleepBlockers: sleepBlockers.blockers)
        }
        // Only checked while the page is open.
        .onAppear { sleepBlockers.start() }
        .onDisappear { sleepBlockers.stop() }
        .navigationTitle("This Mac")
        .toolbar { AdvancedViewerButton(target: AdvancedTarget.mac) }
    }
}

/// The detail cards, separate from the scroll view so they can also be rendered offscreen.
struct MacDetailContent: View {
    /// This Mac's health trend from its history, if any.
    var trend: HealthTrend?
    /// Sleeps on battery, newest first.
    var sleepSessions: [SleepSession] = []
    /// Saved power readings and sleeps for the power chart.
    var powerMinutes: [PowerMinute] = []
    var sleepPeriods: [DateInterval] = []
    /// Apps preventing sleep right now.
    var sleepBlockers: [SleepBlocker] = []
    @EnvironmentObject private var monitor: BatteryMonitor
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.capacityUnit) private var capacityUnit = CapacityUnit.milliampHours
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.defaultStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let battery = monitor.battery {
                batterySection(battery)
                if !sleepBlockers.isEmpty {
                    PreventingSleepCard(blockers: sleepBlockers)
                }
                powerSection(battery)
                AppEnergyCard()
                if battery.isExternalPowerConnected, let adapter = battery.adapter {
                    ChargerCard(adapter: adapter, inputWatts: chargerInputWatts(battery),
                                advice: ChargerCheck.advice(battery: battery, inputWatts: chargerInputWatts(battery),
                                                            systemWatts: monitor.displayedSystemWatts))
                }
                if !sleepSessions.isEmpty {
                    SleepCard(sessions: sleepSessions)
                }
                if !battery.failures.messages.isEmpty {
                    failuresSection(battery.failures)
                }
                if let lifetime = battery.lifetime {
                    LifetimeCard(lifetime: lifetime, cyclesSinceCalibration: battery.cyclesSinceCalibration,
                                 target: AdvancedTarget.mac)
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
            DeviceIcon(modelIdentifier: monitor.macInfo.modelIdentifier, fallbackSymbol: "laptopcomputer")
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
                    tint: .accentColor,
                    decimals: capacityStyle == .raw || battery.powerSource?.chargePercent == nil
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
                    InfoRow("Low Power Mode", monitor.isLowPowerModeEnabled ? "On" : "Off")
                    InfoRow(battery.isCharging ? "Time until full" : "Time until empty",
                            battery.isCalculatingTimeRemaining
                                ? "Calculating…" : battery.timeRemainingMinutes.map(DurationFormat.readable))
                    InfoRow("Charge cycles", cyclesText(battery))
                    InfoRow("Health trend", trend?.summary, hidesWhenEmpty: true)
                    InfoRow("Temperature", battery.temperatureCelsius.map(temperatureUnit.format(celsius:)))
                    if let limit = monitor.chargeLimit {
                        InfoRow("Charge Limit", chargeLimitText(limit), hidesWhenEmpty: true)
                        InfoRow("Optimized Battery Charging", optimizedChargingText(limit), hidesWhenEmpty: true)
                    }
                    InfoRow("macOS health", battery.powerSource?.healthDescription, hidesWhenEmpty: true)
                }
                if let advice = monitor.chargeLimit?.advice(cyclesSinceCalibration: battery.cyclesSinceCalibration) {
                    AdviceBox(advice: advice)
                }
                LowHealthNotice(healthFraction: battery.healthFraction,
                                model: monitor.marketingName ?? monitor.macInfo.modelIdentifier,
                                batteryKey: battery.serialNumber ?? "mac")
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
                        let flow = BatteryFlow.describe(battery)
                        InfoRow(flow.title, flow.value)
                    }
                    InfoRow("From adapter", watts(monitor.power.adapterWatts))
                    InfoRow("CPU usage", monitor.cpuUsage.map { String(format: "%.0f%%", $0 * 100) })
                    InfoRow("CPU temperature", monitor.power.cpuTemperatureCelsius.map(temperatureUnit.format(celsius:)))
                }
                if monitor.power.systemWatts != nil {
                    PowerChart(live: monitor.powerHistory, minutes: powerMinutes, sleeps: sleepPeriods)
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
                InfoRow("Cell voltages", CellBalance.text(battery.cellVoltagesMillivolts), hidesWhenEmpty: true)
                InfoRow("Amperage", battery.amperageMilliamps.map { "\($0) mA" })
                InfoRow("Battery serial", battery.serialNumber)
                InfoRow("Manufacturer", battery.manufacturer, hidesWhenEmpty: true)
                InfoRow("Manufacture date", manufactureText(battery), hidesWhenEmpty: true)
                InfoRow("Battery age", ageText(battery), hidesWhenEmpty: true)
                InfoRow("First used", battery.firstUseDate?.formatted(date: .abbreviated, time: .omitted),
                        hidesWhenEmpty: true)
                InfoRow("Gas gauge", battery.gasGaugeName)
                InfoRow("Mac serial", monitor.macInfo.serialNumber)
                InfoRow("Mac manufactured", monitor.macInfo.manufactureDate.flatMap(dateText), hidesWhenEmpty: true)
                InfoRow("Up since", monitor.macInfo.bootDate.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                })
            }
            if let advice = CellBalance.advice(battery.cellVoltagesMillivolts) {
                AdviceBox(advice: advice)
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
        if let percent = limit.macOSLimitPercent { parts.append("\(percent)%") }
        if let level = limit.smcChargeLevelLimit { parts.append("\(level)% (set in firmware)") }
        parts += limit.thirdPartyLimiters.map { "set by \($0)" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func optimizedChargingText(_ limit: ChargeLimitStatus) -> String? {
        guard limit.optimizedChargingEnabled else { return nil }
        return limit.optimizedChargingEngaged ? "On (holding charge)" : "On"
    }

    private func statusText(_ battery: MacBatterySnapshot) -> String {
        if battery.isFullyCharged { return "Fully charged" }
        if battery.isCharging { return "Charging" }
        if battery.isExternalPowerConnected { return "Plugged in, not charging" }
        return "On battery"
    }

    /// The power controller's measurement, else the SMC's.
    private func chargerInputWatts(_ battery: MacBatterySnapshot) -> Double? {
        battery.chargerInputMilliwatts.map { Double($0) / 1000 } ?? monitor.power.adapterWatts
    }

    private func watts(_ value: Double?) -> String? {
        value.map { String(format: "%.1f W", $0) }
    }

    private func manufactureText(_ battery: MacBatterySnapshot) -> String? {
        if let best = battery.bestManufactureDate { return ManufactureDateText.format(best) }
        guard let week = battery.manufactureWeek else { return nil }
        let month = Calendar.current.monthSymbols[week.month - 1]
        return "Week \(week.week) (\(month)), year not recorded"
    }

    private func ageText(_ battery: MacBatterySnapshot) -> String? {
        guard let start = battery.bestManufactureDate?.date else { return nil }
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

/// The product icon macOS has for a model identifier (e.g. "iPhone19,7"), falling
/// back to an SF Symbol.
struct DeviceIcon: View {
    let modelIdentifier: String?
    let fallbackSymbol: String
    var size: CGFloat = 56

    var body: some View {
        if let type = modelIdentifier.flatMap(DeviceModels.type(for:)) {
            Image(nsImage: NSWorkspace.shared.icon(for: type))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.7, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

enum ManufactureDateText {
    /// "11 Aug 2025", marked "(estimated)" when it comes from operating time.
    static func format(_ best: (date: Date, source: MacBatterySnapshot.ManufactureDateSource)) -> String {
        let date = best.date.formatted(date: .abbreviated, time: .omitted)
        return best.source == .operatingTime ? "\(date) (estimated)" : date
    }
}

/// Gas-gauge lifetime statistics; shared by the Mac and iPhone/iPad pages.
struct LifetimeCard: View {
    let lifetime: BatteryLifetime
    let cyclesSinceCalibration: Int?
    /// Device for the "Lifetime Details…" button.
    let target: String
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
            LifetimeDetailsButton(target: target)
                .controlSize(.small)
        }
    }

    private func range(_ low: Double?, _ high: Double?, _ format: (Double) -> String) -> String? {
        guard let low, let high else { return nil }
        return "\(format(low)) – \(format(high))"
    }
}

/// The connected charger and what it means for charging; shared by the Mac and iPhone/iPad pages.
struct ChargerCard: View {
    let adapter: PowerAdapter
    let inputWatts: Double?
    let advice: [BatteryAdvice]

    var body: some View {
        Card(title: "Charger", systemImage: "powerplug.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    InfoRow("Charger", adapter.name ?? (adapter.isWireless ? "Wireless charger" : "Unknown"))
                    InfoRow("Made by", adapter.manufacturer, hidesWhenEmpty: true)
                    InfoRow("Agreed power", agreedText)
                    InfoRow("Charger offers", ChargerCheck.profilesText(adapter), hidesWhenEmpty: true)
                    InfoRow("Drawing now", drawingText, hidesWhenEmpty: true)
                }
                ForEach(advice, id: \.message) { AdviceBox(advice: $0) }
            }
        }
    }

    /// "30 W (20 V × 1.49 A)".
    private var agreedText: String? {
        let watts = adapter.watts.flatMap { $0 > 0 ? "\($0) W" : nil }
        let detail = ChargerCheck.agreedText(adapter)
        guard let watts else { return detail }
        return detail.map { "\(watts) (\($0))" } ?? watts
    }

    /// "28.2 W (94% of agreed)".
    private var drawingText: String? {
        guard let inputWatts, inputWatts > 0 else { return nil }
        let text = String(format: "%.1f W", inputWatts)
        guard let agreed = ChargerCheck.agreedWatts(adapter), agreed > 0 else { return text }
        return "\(text) (\(Int((inputWatts / agreed * 100).rounded()))% of agreed)"
    }
}

/// Charge lost while the Mac slept on battery.
struct SleepCard: View {
    /// Newest first.
    let sessions: [SleepSession]
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        Card(title: "Sleep", systemImage: "moon.zzz.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    if let last = sessions.first {
                        InfoRow("Last sleep", SleepDrain.summary(last))
                        // The wake date too when it woke on a later day.
                        InfoRow("Slept", "\(last.start.formatted(date: .abbreviated, time: .shortened)) – "
                            + last.end.formatted(date: Calendar.current.isDate(last.end, inSameDayAs: last.start)
                                ? .omitted : .abbreviated, time: .shortened))
                    }
                    if sessions.count > 1 {
                        let recent = Array(sessions.prefix(10))
                        InfoRow("Average", SleepDrain.averageLossPerHour(recent).map {
                            String(format: "%.1f%% an hour over the last %d sleeps", $0 * 100, recent.count)
                        })
                    }
                }
                if let advice = SleepDrain.advice(sessions) {
                    AdviceBox(advice: advice)
                }
                Text("Sleeps of \(Int(SleepSession.minimumDuration / 60)) minutes or more on battery are measured; "
                    + "shorter ones are too brief for the battery gauge to show the loss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show All Sleeps…") { navigator.selection = .sleep }
                    .controlSize(.small)
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        // GroupBox for the system's fill and corners, which follow the macOS release.
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                content
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AdviceBox: View {
    let advice: BatteryAdvice

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
    /// Off for whole-number percentages such as macOS's, which would read "89.0%".
    var decimals = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(fraction.map { String(format: decimals ? "%.1f%%" : "%.0f%%", $0 * 100) } ?? "—")
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
