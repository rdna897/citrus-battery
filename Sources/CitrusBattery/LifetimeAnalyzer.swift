import AppKit
import CitrusKit
import SwiftUI

/// "Battery Lifetime Data": the gauge's lifetime statistics for this Mac or a
/// connected iPhone/iPad, as a name/value table.
struct LifetimeAnalyzer: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var iosDevices: IOSDeviceMonitor
    @EnvironmentObject private var navigator: Navigator
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @ViewState private var selectedRows = Set<LifetimeReport.Row.ID>()

    var body: some View {
        NavigationSplitView {
            List(selection: $navigator.lifetimeTarget) {
                Section("Available Devices") {
                    Label("This Mac", systemImage: "laptopcomputer")
                        .tag(AdvancedTarget.mac)
                    ForEach(iosDevices.devices.filter { $0.snapshot?.battery != nil }) { device in
                        Label(device.displayName, systemImage: device.symbolName)
                            .tag(device.udid)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            if rows.isEmpty {
                Text("Battery not supported. This battery doesn't record lifetime data.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $selectedRows) {
                    TableColumn("Name", value: \.name)
                        .width(min: 150, ideal: 190)
                    TableColumn("Value") { row in
                        Text(row.value).textSelection(.enabled)
                    }
                }
                .contextMenu(forSelectionType: LifetimeReport.Row.ID.self) { ids in
                    Button("Copy") { copy(rows.filter { ids.contains($0.id) }) }
                }
            }
        }
        .navigationTitle("Battery Lifetime Data")
        .navigationSubtitle(subtitle)
        .toolbar {
            Button {
                copy(rows)
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .help("Copy every value as tab-separated text")
            .disabled(rows.isEmpty)
        }
        .frame(minWidth: 560, minHeight: 380)
    }

    private var battery: MacBatterySnapshot? {
        if navigator.lifetimeTarget == AdvancedTarget.mac { return monitor.battery }
        return iosDevices.device(udid: navigator.lifetimeTarget)?.snapshot?.battery
    }

    private var rows: [LifetimeReport.Row] {
        battery.map { LifetimeReport.rows(for: $0, temperatureUnit: temperatureUnit) } ?? []
    }

    private var subtitle: String {
        if navigator.lifetimeTarget == AdvancedTarget.mac { return monitor.marketingName ?? "This Mac" }
        return iosDevices.device(udid: navigator.lifetimeTarget)?.displayName ?? ""
    }

    private func copy(_ rows: [LifetimeReport.Row]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.map { "\($0.name)\t\($0.value)" }.joined(separator: "\n"),
                                       forType: .string)
    }
}

/// Opens the lifetime window on a given device.
struct LifetimeDetailsButton: View {
    let target: String
    @EnvironmentObject private var navigator: Navigator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Lifetime Details…") {
            navigator.lifetimeTarget = target
            openWindow(id: "lifetime")
        }
    }
}
