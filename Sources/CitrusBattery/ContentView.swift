import SwiftUI

enum SidebarItem: Hashable {
    case thisMac
    case history
}

struct ContentView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var navigator: Navigator

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
            case .history:
                HistoryView()
            }
        }
    }
}
