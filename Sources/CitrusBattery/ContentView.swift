import SwiftUI

enum SidebarItem: Hashable {
    case thisMac
    case device(String)
    case history
}

struct ContentView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var iosDevices: IOSDeviceMonitor

    var body: some View {
        NavigationSplitView {
            List(selection: $navigator.selection) {
                Section("Devices") {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("This Mac")
                            Text(monitor.marketingName ?? monitor.macInfo.modelIdentifier)
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
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            switch navigator.selection {
            case .thisMac, nil:
                MacDetailView()
            case let .device(udid):
                IOSDetailView(udid: udid)
            case .history:
                HistoryView()
            }
        }
    }

    private func subtitle(for device: TrackedDevice) -> String {
        switch device.state {
        case .ready:
            let charge = device.snapshot?.battery?.chargeFraction(style: .apple).map { "\(Int(($0 * 100).rounded()))%" }
            return [device.snapshot?.marketingName, charge].compactMap { $0 }.joined(separator: " · ")
        case .notTrusted: return "Tap Trust on the device"
        case .locked: return "Unlock the device"
        case .unavailable: return "Can't read"
        case .disconnected: return "Disconnected"
        }
    }
}
