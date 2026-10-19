import CitrusKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            BatterySettings()
                .tabItem { Label("Battery", systemImage: "battery.100percent") }
        }
        .frame(width: 460)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius

    var body: some View {
        Form {
            Picker("Temperature unit:", selection: $temperatureUnit) {
                ForEach(TemperatureUnit.allCases) { unit in
                    Text("\(unit.name) (\(unit.symbol))").tag(unit)
                }
            }
            Text("Used everywhere Citrus Battery shows a temperature.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BatterySettings: View {
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.raw
    @AppStorage(PreferenceKey.capacityUnit) private var capacityUnit = CapacityUnit.milliampHours
    @AppStorage(PreferenceKey.updateInterval) private var updateInterval = UpdateInterval.delayed

    var body: some View {
        Form {
            Picker("Charge percentage:", selection: $capacityStyle) {
                ForEach(CapacityStyle.allCases) { Text($0.name).tag($0) }
            }
            Text("Raw values come straight from the battery; macOS style matches the menu bar. Affects the live view only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Capacity units:", selection: $capacityUnit) {
                ForEach(CapacityUnit.allCases) { Text($0.name).tag($0) }
            }

            Picker("Update interval:", selection: $updateInterval) {
                ForEach(UpdateInterval.allCases) { Text($0.name).tag($0) }
            }
            Text("Delayed refreshes every 5 seconds and averages power over 30 seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
