import CitrusKit
import SwiftUI

struct IOSDetailView: View {
    let udid: String
    @EnvironmentObject private var devices: IOSDeviceMonitor

    var body: some View {
        ScrollView {
            if let device = devices.device(udid: udid) {
                IOSDetailContent(device: device)
            } else {
                Text("This device is no longer connected.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .navigationTitle(devices.device(udid: udid)?.displayName ?? "Device")
        .toolbar {
            AdvancedViewerButton(target: udid)
            Button {
                devices.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(devices.isRefreshing)
            .help("Read the device again")
        }
    }
}

struct IOSDetailContent: View {
    let device: TrackedDevice
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.capacityUnit) private var capacityUnit = CapacityUnit.milliampHours

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let message = stateMessage {
                Card(title: message.title, systemImage: message.symbol) {
                    Text(message.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let snapshot = device.snapshot {
                if let battery = snapshot.battery {
                    batteryCard(battery)
                    if let lifetime = battery.lifetime {
                        LifetimeCard(lifetime: lifetime, cyclesSinceCalibration: battery.cyclesSinceCalibration)
                    }
                    detailsCard(snapshot, battery: battery)
                } else {
                    Card(title: "Battery", systemImage: "battery.0percent") {
                        Text("This device didn't return battery data.")
                            .foregroundStyle(.secondary)
                    }
                    detailsCard(snapshot, battery: nil)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            DeviceIcon(modelIdentifier: device.snapshot?.productType, fallbackSymbol: device.symbolName)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.title2.weight(.semibold))
                if let snapshot = device.snapshot {
                    Text([snapshot.marketingName, snapshot.osVersion.map { "iOS \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Text(connectionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionText: String {
        let via = device.connection.map { $0 == .wifi ? "WiFi" : "USB" }
        switch device.state {
        case .disconnected:
            return device.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Disconnected"
        default:
            let seen = device.lastSeen.map { "updated \($0.formatted(date: .omitted, time: .shortened))" }
            return [via.map { "Connected via \($0)" }, seen].compactMap { $0 }.joined(separator: ", ")
        }
    }

    private var stateMessage: (title: String, symbol: String, body: String)? {
        switch device.state {
        case .notTrusted:
            ("Trust required", "lock.shield",
             "Unlock the device and tap Trust when it asks whether to trust this computer.")
        case .locked:
            ("Device locked", "lock.fill", "Unlock the device so Citrus Battery can read it.")
        case .unavailable:
            ("Couldn't read the device", "exclamationmark.triangle",
             "Citrus Battery will try again shortly. Reconnecting the cable can help.")
        case .disconnected where device.snapshot != nil:
            ("Disconnected", "cable.connector.slash",
             "Showing the last reading. Connect the device again to update it.")
        case .ready, .disconnected:
            nil
        }
    }

    private func batteryCard(_ battery: MacBatterySnapshot) -> some View {
        Card(title: "Battery", systemImage: "battery.100percent") {
            VStack(alignment: .leading, spacing: 14) {
                MeterRow(title: "Current charge", fraction: battery.chargeFraction(style: .apple),
                         detail: capacity(battery.currentCapacity, battery), tint: .accentColor)
                MeterRow(title: "Battery health", fraction: battery.healthFraction,
                         detail: capacity(battery.fullChargeCapacity, battery).map { "\($0) of " }
                             .map { $0 + (capacity(battery.designCapacity, battery) ?? "—") },
                         tint: healthColour(battery.healthFraction))
                Divider()
                if battery.isChargingPausedBySettings {
                    AdviceBox(advice: ChargeLimitAdvice(
                        level: .info,
                        message: "iOS has paused charging because of its charging settings (Charge Limit or "
                            + "charging optimization). iOS occasionally charges to 100% to keep its battery "
                            + "estimates accurate, so this won't skew the reported capacity."))
                }
                LowHealthNotice(healthFraction: battery.healthFraction,
                                model: device.snapshot?.marketingName ?? "iPhone",
                                batteryKey: battery.serialNumber ?? device.udid)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    InfoRow("Status", status(battery))
                    InfoRow("Charge cycles", battery.cycleCount.map(String.init))
                    InfoRow("Temperature", battery.temperatureCelsius.map(temperatureUnit.format(celsius:)))
                    InfoRow(battery.isCharging ? "Charging with" : "Discharging with",
                            // A zero reading means the current wasn't reported (common over WiFi).
                            battery.batteryPowerWatts.flatMap { abs($0) < 0.05 ? nil : String(format: "%.1f W", abs($0)) },
                            hidesWhenEmpty: true)
                    InfoRow("Charger", battery.adapter?.watts.flatMap { $0 > 0 ? "\($0) W" : nil }, hidesWhenEmpty: true)
                }
            }
        }
    }

    private func detailsCard(_ snapshot: IOSDeviceSnapshot, battery: MacBatterySnapshot?) -> some View {
        Card(title: "Details", systemImage: "info.circle.fill") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                InfoRow("Model", "\(snapshot.marketingName) (\(snapshot.productType))")
                InfoRow("Model number", snapshot.modelNumber, hidesWhenEmpty: true)
                InfoRow("Serial number", snapshot.serialNumber, hidesWhenEmpty: true)
                InfoRow("Battery serial", battery?.serialNumber, hidesWhenEmpty: true)
                InfoRow("Battery manufacturer", battery?.manufacturer, hidesWhenEmpty: true)
                InfoRow("Manufactured", battery?.estimatedManufactureDate.map {
                    "≈ \($0.formatted(date: .abbreviated, time: .omitted)) (estimated from operating time)"
                }, hidesWhenEmpty: true)
                InfoRow("First used", battery?.firstUseDate?.formatted(date: .abbreviated, time: .omitted),
                        hidesWhenEmpty: true)
                InfoRow("Full charge capacity", capacity(battery?.fullChargeCapacity, battery), hidesWhenEmpty: true)
                InfoRow("Design capacity", capacity(battery?.designCapacity, battery), hidesWhenEmpty: true)
                InfoRow("Voltage", battery?.voltageMillivolts.map { String(format: "%.2f V", Double($0) / 1000) },
                        hidesWhenEmpty: true)
            }
        }
    }

    private func capacity(_ mAh: Int?, _ battery: MacBatterySnapshot?) -> String? {
        mAh.map { capacityUnit.format(milliampHours: $0, voltageMillivolts: battery?.voltageMillivolts) }
    }

    private func status(_ battery: MacBatterySnapshot) -> String {
        if battery.isFullyCharged { return "Fully charged" }
        if battery.isCharging { return "Charging" }
        if battery.isChargingPausedBySettings { return "Charging paused by iOS (charging settings)" }
        return battery.isExternalPowerConnected ? "Connected, not charging" : "On battery"
    }

    private func healthColour(_ fraction: Double?) -> Color {
        switch fraction ?? 1 {
        case 0.8...: .green
        case 0.6..<0.8: .yellow
        default: .red
        }
    }
}
