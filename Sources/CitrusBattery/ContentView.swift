import SwiftUI

enum SidebarItem: Hashable {
    case thisMac
    case device(String)
    case history
    case sleep
    case settings
}

/// The two lists of the sidebar, which share one selection.
private enum SidebarList: Hashable {
    case pages, settings

    init(for selection: SidebarItem?) {
        self = selection == .settings ? .settings : .pages
    }
}

struct ContentView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var iosDevices: IOSDeviceMonitor
    @Environment(\.openWindow) private var openWindow
    /// Which sidebar list has focus: the pages, or Settings under them.
    @FocusState private var focusedList: SidebarList?

    var body: some View {
        NavigationSplitView {
            List(selection: $navigator.selection) {
                Section("Devices") {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("This Mac")
                            Text(shortModelName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "laptopcomputer")
                    }
                    .tag(SidebarItem.thisMac)
                    ForEach(iosDevices.devices) { device in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.displayName)
                                Text(subtitle(for: device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: device.symbolName)
                        }
                        .tag(SidebarItem.device(device.udid))
                    }
                }
                Section("Data") {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.history)
                    Label("Sleep", systemImage: "moon.zzz")
                        .tag(SidebarItem.sleep)
                }
            }
            .focused($focusedList, equals: .pages)
            .safeAreaInset(edge: .bottom, spacing: 0) { settingsFooter }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            // A list shows its selection in the accent colour only while it has
            // focus, so move focus to whichever list holds the selection.
            .onChange(of: navigator.selection) { focusedList = SidebarList(for: $0) }
            .onAppear { focusedList = SidebarList(for: navigator.selection) }
        } detail: {
            detail
        }
        .onOpenURL { handle($0, openWindow: openWindow) }
    }

    @ViewBuilder
    private var detail: some View {
            switch navigator.selection {
            case .thisMac, nil:
                MacDetailView()
            case let .device(udid):
                IOSDetailView(udid: udid)
            case .history:
                HistoryView()
            case .sleep:
                SleepView()
            case .settings:
                SettingsView()
            }
    }

    /// Settings pinned under the list: a one-row sidebar list sharing the
    /// selection, so it's highlighted exactly like the pages above it.
    private var settingsFooter: some View {
        List(selection: $navigator.selection) {
            Label("Settings", systemImage: "gearshape")
                .tag(SidebarItem.settings)
        }
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .frame(height: 44)
        .focused($focusedList, equals: .settings)
    }

    /// citrusbattery:// links (see CitrusURL).
    func handle(_ url: URL, openWindow: OpenWindowAction) {
        switch CitrusURL.route(url) {
        case let .select(item): navigator.selection = item
        case let .advanced(target): openWindow(id: "advanced", value: target)
        case let .lifetime(target):
            navigator.lifetimeTarget = target
            openWindow(id: "lifetime")
        case nil: break
        }
    }

    /// "MacBook Air (13-inch, M4, 2025)" → "MacBook Air"; the page shows the full name.
    private var shortModelName: String {
        guard let name = monitor.marketingName else { return monitor.macInfo.modelIdentifier }
        return name.components(separatedBy: " (").first ?? name
    }

    private func subtitle(for device: TrackedDevice) -> String {
        switch device.state {
        case .ready:
            let battery = device.snapshot?.battery
            let charge = battery?.chargeFraction(style: .apple).map { "\(Int(($0 * 100).rounded()))%" }
            let paused = battery?.isChargingPausedBySettings == true ? " ⏸︎" : ""
            return [device.snapshot?.marketingName, charge.map { $0 + paused }].compactMap { $0 }.joined(separator: " · ")
        case .notTrusted: return "Tap Trust on the device"
        case .locked: return "Unlock the device"
        case .unavailable: return "Can't read"
        case .disconnected: return "Disconnected"
        }
    }
}
