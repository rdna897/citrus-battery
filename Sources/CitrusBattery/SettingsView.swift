import CitrusKit
import SwiftUI

/// The sections of the Settings page.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, battery, menuBar, notifications, history, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .battery: "Battery"
        case .menuBar: "Menu Bar"
        case .notifications: "Notifications"
        case .history: "History"
        case .updates: "Updates"
        }
    }
}

/// Settings, shown as a page of the main window: a section picker above
/// grouped forms like System Settings'.
struct SettingsView: View {
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $navigator.settingsSection) {
                ForEach(SettingsSection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 20)
            section
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .toggleStyle(.switch)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .navigationTitle("Settings")
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var section: some View {
        switch navigator.settingsSection {
        case .general: GeneralSettings()
        case .battery: BatterySettings()
        case .menuBar: MenuBarSettings()
        case .notifications: NotificationSettings()
        case .history: HistorySettings()
        case .updates: UpdateSettings()
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius

    var body: some View {
        Form {
            Section {
                Picker("Temperature unit", selection: $temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text("\(unit.name) (\(unit.symbol))").tag(unit)
                    }
                }
            } footer: {
                SettingsNote("Used everywhere Citrus Battery shows a temperature.")
            }
        }
    }
}

private struct BatterySettings: View {
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.defaultStyle
    @AppStorage(PreferenceKey.capacityUnit) private var capacityUnit = CapacityUnit.milliampHours
    @AppStorage(PreferenceKey.updateInterval) private var updateInterval = UpdateInterval.delayed

    var body: some View {
        Form {
            Section {
                Picker("Charge percentage", selection: $capacityStyle) {
                    ForEach(CapacityStyle.allCases) { Text($0.name).tag($0) }
                }
                Picker("Capacity units", selection: $capacityUnit) {
                    ForEach(CapacityUnit.allCases) { Text($0.name).tag($0) }
                }
            } header: {
                Text("Display")
            } footer: {
                SettingsNote("Raw values come straight from the battery; macOS style matches the menu bar. Affects the live view only.")
            }
            Section {
                Picker("Update interval", selection: $updateInterval) {
                    ForEach(UpdateInterval.allCases) { Text($0.name).tag($0) }
                }
            } header: {
                Text("Refresh")
            } footer: {
                SettingsNote("Delayed refreshes every 5 seconds and averages power over 30 seconds.")
            }
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
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.defaultStyle
    @ViewState private var openAtLogin = LaunchAtLogin.isEnabled
    @ViewState private var loginError: String?
    /// The side to restore when the icon is turned back on.
    @ViewState private var lastIconSide = BatterySymbolPosition.left

    var body: some View {
        Form {
            Section {
                Toggle("Show Citrus Battery in the menu bar", isOn: $showInMenuBar)
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .disabled(!showInMenuBar)
                    .help("Hide the Dock icon to run Citrus Battery from the menu bar only.")
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
                if openAtLogin {
                    Toggle(showInMenuBar ? "Start in the menu bar, without opening the window"
                                         : "Start with the window minimised", isOn: $startHiddenAtLogin)
                        .help("Applies when Citrus Battery opens at login, such as after a restart.")
                }
            } footer: {
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent("Preview") {
                    HStack(spacing: 10) {
                        MenuBarLabel(inMenuBar: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        Button("Use Default") { format = MenuBarToken.defaultFormat }
                            .disabled(format == MenuBarToken.defaultFormat)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shown in the menu bar")
                    if shownTokens.isEmpty {
                        Text("Nothing: only the battery icon")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 4) {
                            ForEach(shownTokens) { token in
                                Button(token.title) { setShown(shownTokens.filter { $0 != token }) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .help("Remove from the menu bar")
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Available")
                    if availableTokens.isEmpty {
                        Text("Everything is shown")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 4) {
                            ForEach(availableTokens) { token in
                                Button(token.title) { setShown(shownTokens + [token]) }
                                    .controlSize(.small)
                                    .help("Add to the menu bar")
                            }
                        }
                    }
                }
            } header: {
                Text("Menu bar text")
            } footer: {
                SettingsNote("Click an item to add it to the menu bar or remove it.")
            }

            Section {
                Toggle("Show battery icon", isOn: showIcon)
                    .disabled(shownTokens.isEmpty)
                if showsIcon {
                    if SystemBatteryIcon.isAvailable {
                        Toggle("Show percentage inside the icon", isOn: $percentInIcon)
                            .help("Writes the charge inside the icon, as macOS does. "
                                + "Remove Charge % from the menu bar text to show it only there.")
                    }
                    if !shownTokens.isEmpty {
                        Picker("Position", selection: iconSide) {
                            Text("Left of the text").tag(BatterySymbolPosition.left)
                            Text("Right of the text").tag(BatterySymbolPosition.right)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            } header: {
                Text("Battery icon")
            } footer: {
                if shownTokens.isEmpty {
                    SettingsNote("The icon always shows while there's no menu bar text.")
                }
            }

            Section {
                Toggle("Show connected iPhones and iPads", isOn: $showDevices)
            } header: {
                Text("Menu bar panel")
            }
        }
        .onAppear { openAtLogin = LaunchAtLogin.isEnabled }
    }

    private var shownTokens: [MenuBarToken] { MenuBarToken.tokens(in: format) }

    /// With no text the menu bar shows the icon whatever the setting says.
    private var showsIcon: Bool { symbolPosition != .none || shownTokens.isEmpty }

    private var showIcon: Binding<Bool> {
        Binding(get: { showsIcon }, set: { show in
            if show {
                symbolPosition = lastIconSide
            } else {
                lastIconSide = iconSide.wrappedValue
                symbolPosition = .none
            }
        })
    }

    /// Left or right of the text; `.none` reads as left so the picker always has a choice.
    private var iconSide: Binding<BatterySymbolPosition> {
        Binding(get: { symbolPosition == .right ? .right : .left }, set: { symbolPosition = $0 })
    }
    private var availableTokens: [MenuBarToken] { MenuBarToken.allCases.filter { !shownTokens.contains($0) } }

    private func setShown(_ tokens: [MenuBarToken]) {
        withAnimation(.easeInOut(duration: 0.15)) { format = MenuBarToken.format(tokens) }
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
            if !notifier.isAvailable || notifier.authorization == .denied {
                Section {
                    Text(notifier.isAvailable
                         ? "Notifications are turned off for Citrus Battery in System Settings."
                         : "Notifications need Citrus Battery to run as an app (build it with scripts/build-app.sh).")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Toggle("Low charge", isOn: $lowChargeEnabled)
                if lowChargeEnabled {
                    Picker("Notify below", selection: $lowChargePercent) {
                        ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
                Toggle("Low time remaining", isOn: $lowTimeEnabled)
                if lowTimeEnabled {
                    Picker("Notify below", selection: $lowTimeMinutes) {
                        Text("10 minutes").tag(10)
                        Text("20 minutes").tag(20)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                }
                Toggle("Fully charged", isOn: $fullyCharged)
            } header: {
                Text("This Mac")
            } footer: {
                SettingsNote("Each alert fires once per discharge and again after you plug in, at most every 15 minutes.")
            }

            Section {
                Toggle("Charged to a level", isOn: $deviceChargeEnabled)
                if deviceChargeEnabled {
                    Picker("Notify at", selection: $deviceChargePercent) {
                        ForEach([50, 60, 70, 75, 80, 85, 90, 95, 100], id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
            } header: {
                Text("iPhone and iPad")
            } footer: {
                SettingsNote("Fires once per charge, and again after the device drops 5% below the level.")
            }

            Section {
                HStack {
                    Button("Send Test Notification") { notifier.sendTest() }
                    Spacer()
                    Button("macOS Notification Settings…") {
                        let id = Bundle.main.bundleIdentifier ?? ""
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .disabled(!notifier.isAvailable)
            }
        }
        .onChange(of: [lowChargeEnabled, lowTimeEnabled, fullyCharged, deviceChargeEnabled]) { enabled in
            if enabled.contains(true) { notifier.requestAuthorization() }
        }
        .onAppear { notifier.refreshAuthorization() }
    }
}

private struct HistorySettings: View {
    @EnvironmentObject private var history: HistoryController
    @AppStorage(PreferenceKey.autosaveNewDevices) private var autoRecordNewDevices = true

    var body: some View {
        Form {
            Section {
                Toggle("Auto-record new devices", isOn: $autoRecordNewDevices)
                    .onChange(of: autoRecordNewDevices) { _ in history.reload() }
            } footer: {
                SettingsNote("Auto-Record saves a device's battery data about once an hour, skipping readings that "
                    + "haven't changed since earlier the same day. You can turn it off per device on the "
                    + "History page.")
            }
        }
    }
}

private struct UpdateSettings: View {
    @EnvironmentObject private var updater: AppUpdater

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(development build)"
    }

    @ViewBuilder
    private var statusLine: some View {
        switch updater.status {
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking for updates…")
            }
        case .upToDate:
            Text("Up to date")
        case let .available(newVersion):
            Text("Version \(newVersion) is available")
        case .failed:
            Text("Couldn't check for updates. Check your internet connection and try again.")
        case .idle:
            if let date = updater.lastUpdateCheckDate {
                Text("Last checked \(date.formatted(.dateTime.month().day().hour().minute()))")
            } else {
                Text("Not checked yet")
            }
        }
    }

    var body: some View {
        Form {
            Section {
                // As in Software Update: the result of the last check in place,
                // with no windows until there's an update to look at.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Citrus Battery \(version)")
                        statusLine
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .available = updater.status {
                        Button("Update Now…", action: updater.checkForUpdates)
                            .buttonStyle(.borderedProminent)
                            .disabled(!updater.canCheckForUpdates)
                    } else {
                        Button("Check Now", action: updater.checkForUpdatesQuietly)
                            .disabled(!updater.canCheckForUpdates || updater.status == .checking)
                    }
                }
            } footer: {
                if !updater.isAvailable {
                    SettingsNote("Updates are available in the packaged application. Download it from GitHub Releases.")
                }
            }
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { enabled in updater.setAutomaticallyChecksForUpdates(enabled) }))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { enabled in updater.setAutomaticallyDownloadsUpdates(enabled) }))
                    .disabled(!updater.automaticallyChecksForUpdates)
            } footer: {
                SettingsNote("Checks GitHub once a day. Automatic updates install when you quit Citrus Battery.")
            }
            .disabled(!updater.isAvailable)
        }
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
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
