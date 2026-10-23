import CitrusKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
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

private struct UpdateSettings: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Form {
            LabeledContent("Installed version:") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build")
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { enabled in updater.setAutomaticallyChecksForUpdates(enabled) }))
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { enabled in updater.setAutomaticallyDownloadsUpdates(enabled) }))
                .disabled(!updater.automaticallyChecksForUpdates)
            SettingsNote("Checks GitHub daily. With automatic installation on, updates download in the background and install when Citrus Battery quits; otherwise each update is shown first.")
            if let date = updater.lastUpdateCheckDate {
                LabeledContent("Last checked:") {
                    Text(date, format: .dateTime.month().day().hour().minute())
                }
            }
            CheckForUpdatesButton(updater: updater)
            if !updater.isAvailable {
                SettingsNote("Updates are available in the packaged application. Download it from GitHub Releases.")
            }
        }
        .disabled(!updater.isAvailable)
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
            SettingsNote("Used everywhere Citrus Battery shows a temperature.")
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
            SettingsNote("Raw values come straight from the battery; macOS style matches the menu bar. Affects the live view only.")

            Picker("Capacity units:", selection: $capacityUnit) {
                ForEach(CapacityUnit.allCases) { Text($0.name).tag($0) }
            }

            Picker("Update interval:", selection: $updateInterval) {
                ForEach(UpdateInterval.allCases) { Text($0.name).tag($0) }
            }
            SettingsNote("Delayed refreshes every 5 seconds and averages power over 30 seconds.")
        }
    }
}

private struct HistorySettings: View {
    @EnvironmentObject private var history: HistoryController
    @AppStorage(PreferenceKey.autosaveNewDevices) private var autoRecordNewDevices = true

    var body: some View {
        Form {
            Toggle("Auto-record new devices", isOn: $autoRecordNewDevices)
                .onChange(of: autoRecordNewDevices) { _ in history.reload() }
            SettingsNote("Auto-Record saves a device's battery data about once an hour, skipping readings that "
                + "haven't changed since earlier the same day. You can turn it off per device in the "
                + "History window.")
        }
    }
}

private struct MenuBarSettings: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @AppStorage(PreferenceKey.showInMenuBar) private var showInMenuBar = true
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = true
    @AppStorage(PreferenceKey.startHiddenAtLogin) private var startHiddenAtLogin = true
    @AppStorage(PreferenceKey.menuBarFormat) private var format = MenuBarToken.defaultFormat
    @AppStorage(PreferenceKey.batterySymbol) private var symbolPosition = BatterySymbolPosition.left
    @AppStorage(PreferenceKey.batteryPercentInIcon) private var percentInIcon = false
    @AppStorage(PreferenceKey.showDevicesInMenuBar) private var showDevices = true
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
            Toggle(showInMenuBar ? "Start in the menu bar, without opening the window"
                                 : "Start with the window minimised", isOn: $startHiddenAtLogin)
                .disabled(!openAtLogin)
                .padding(.leading, 20)
                .help("Applies when Citrus Battery opens at login, such as after a restart.")
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show Dock icon", isOn: $showDockIcon)
                .disabled(!showInMenuBar)
                .help("Hide the Dock icon to run Citrus Battery from the menu bar only.")

            Divider()

            LabeledContent("Menu bar text:") {
                TextField("Menu bar text", text: $format)
                    .labelsHidden()
                    .font(.body.monospaced())
            }
            LabeledContent("Insert:") {
                FlowLayout(spacing: 4) {
                    ForEach(MenuBarToken.allCases) { token in
                        Button(token.title) { format += (format.isEmpty ? "" : " ") + token.rawValue }
                            .controlSize(.small)
                    }
                }
            }
            LabeledContent("Preview:") {
                HStack {
                    MenuBarLabel(inMenuBar: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                    Button("Use Default") { format = MenuBarToken.defaultFormat }
                }
            }
            Picker("Battery icon:", selection: $symbolPosition) {
                ForEach(BatterySymbolPosition.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            if SystemBatteryIcon.isAvailable {
                Toggle("Show percentage inside the battery icon", isOn: $percentInIcon)
                    .disabled(symbolPosition == .none && !format.isEmpty)
                    .help("Writes the charge inside the icon, as macOS does. "
                        + "Remove %CHARGE% from the menu bar text to show it only there.")
            }
            Toggle("Show connected iPhones and iPads in the menu bar panel", isOn: $showDevices)
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
    @AppStorage(PreferenceKey.alertDeviceChargeEnabled) private var deviceChargeEnabled = false
    @AppStorage(PreferenceKey.alertDeviceChargePercent) private var deviceChargePercent = 80

    var body: some View {
        Form {
            Text("This Mac").font(.headline)
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

            SettingsNote("Each alert fires once per discharge and again after you plug in, at most every 15 minutes.")

            Text("iPhone and iPad").font(.headline).padding(.top, 6)
            HStack {
                Toggle("Notify when a connected device charges to", isOn: $deviceChargeEnabled)
                Picker("", selection: $deviceChargePercent) {
                    ForEach([50, 60, 70, 75, 80, 85, 90, 95, 100], id: \.self) { Text("\($0)%").tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                .disabled(!deviceChargeEnabled)
            }
            SettingsNote("Fires once per charge, and again after the device drops 5% below the level.")

            Divider()

            if !notifier.isAvailable {
                Text("Notifications need Citrus Battery to run as an app (build it with scripts/build-app.sh).")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if notifier.authorization == .denied {
                Text("Notifications are turned off for Citrus Battery in System Settings.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
        .onChange(of: [lowChargeEnabled, lowTimeEnabled, fullyCharged, deviceChargeEnabled]) { enabled in
            if enabled.contains(true) { notifier.requestAuthorization() }
        }
        .onAppear { notifier.refreshAuthorization() }
    }
}

/// Secondary explanatory text under a setting; wraps instead of truncating.
private struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Lays out children left to right, wrapping onto new lines as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
