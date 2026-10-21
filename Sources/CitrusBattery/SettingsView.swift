import CitrusKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            BatterySettings()
                .tabItem { Label("Battery", systemImage: "battery.100percent") }
            MenuBarSettings()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            HistorySettings()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 540)
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

private struct HistorySettings: View {
    @EnvironmentObject private var history: HistoryController
    @AppStorage(PreferenceKey.autosaveNewDevices) private var autosaveNewDevices = true

    var body: some View {
        Form {
            Toggle("Enable SmartSave for new devices", isOn: $autosaveNewDevices)
                .onChange(of: autosaveNewDevices) { _ in history.reload() }
            Text("SmartSave records a device's battery data about once an hour, skipping readings that "
                + "haven't changed since earlier the same day. You can turn it off per device in the "
                + "History window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MenuBarSettings: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @AppStorage(PreferenceKey.showInMenuBar) private var showInMenuBar = true
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = true
    @AppStorage(PreferenceKey.menuBarFormat) private var format = MenuBarToken.defaultFormat
    @AppStorage(PreferenceKey.batterySymbol) private var symbolPosition = BatterySymbolPosition.left
    @AppStorage(PreferenceKey.menuBarAccentColour) private var useAccentColour = false
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.raw
    @ViewState private var openAtLogin = LaunchAtLogin.isEnabled
    @ViewState private var loginError: String?

    var body: some View {
        Form {
            Toggle("Show Citrus Battery in the menu bar", isOn: $showInMenuBar)
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { enabled in
                    do {
                        try LaunchAtLogin.set(enabled)
                        loginError = LaunchAtLogin.needsApproval
                            ? "Allow Citrus Battery in System Settings → General → Login Items." : nil
                    } catch {
                        loginError = "Couldn't change the login item: \(error.localizedDescription)"
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Show Dock icon", isOn: $showDockIcon)
                .disabled(!showInMenuBar)
                .help("Hide the Dock icon to run Citrus Battery from the menu bar only.")

            Divider()

            TextField("Menu bar text:", text: $format)
                .font(.body.monospaced())
            HStack(spacing: 4) {
                Text("Insert:").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(MenuBarToken.allCases) { token in
                            Button(token.title) { format += (format.isEmpty ? "" : " ") + token.rawValue }
                                .controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                Text("Preview:").foregroundStyle(.secondary)
                MenuBarLabel()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                Spacer()
                Button("Use Default") { format = MenuBarToken.defaultFormat }
            }
            Picker("Battery icon:", selection: $symbolPosition) {
                ForEach(BatterySymbolPosition.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Use the macOS accent colour for charge and health bars", isOn: $useAccentColour)
        }
        .onAppear { openAtLogin = LaunchAtLogin.isEnabled }
    }
}

private struct NotificationSettings: View {
    @EnvironmentObject private var notifier: Notifier
    @AppStorage(PreferenceKey.alertLowChargeEnabled) private var lowChargeEnabled = false
    @AppStorage(PreferenceKey.alertLowChargePercent) private var lowChargePercent = 20
    @AppStorage(PreferenceKey.alertLowTimeEnabled) private var lowTimeEnabled = false
    @AppStorage(PreferenceKey.alertLowTimeMinutes) private var lowTimeMinutes = 30
    @AppStorage(PreferenceKey.alertFullyCharged) private var fullyCharged = false

    var body: some View {
        Form {
            HStack {
                Toggle("Notify when the charge falls below", isOn: $lowChargeEnabled)
                Picker("", selection: $lowChargePercent) {
                    ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                .disabled(!lowChargeEnabled)
            }
            HStack {
                Toggle("Notify when time on battery is below", isOn: $lowTimeEnabled)
                Picker("", selection: $lowTimeMinutes) {
                    Text("10 minutes").tag(10)
                    Text("20 minutes").tag(20)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
                .labelsHidden()
                .frame(width: 120)
                .disabled(!lowTimeEnabled)
            }
            Toggle("Notify when the battery is fully charged", isOn: $fullyCharged)
            Text("Each alert fires once per discharge and again after you plug in, at most every 15 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if !notifier.isAvailable {
                Text("Notifications need Citrus Battery to run as an app (build it with scripts/build-app.sh).")
                    .font(.caption).foregroundStyle(.orange)
            } else if notifier.authorization == .denied {
                Text("Notifications are turned off for Citrus Battery in System Settings.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Send Test Notification") { notifier.sendTest() }
                Button("macOS Notification Settings…") {
                    let id = Bundle.main.bundleIdentifier ?? ""
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .disabled(!notifier.isAvailable)
        }
        .onChange(of: [lowChargeEnabled, lowTimeEnabled, fullyCharged]) { enabled in
            if enabled.contains(true) { notifier.requestAuthorization() }
        }
        .onAppear { notifier.refreshAuthorization() }
    }
}
