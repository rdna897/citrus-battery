import SwiftUI

enum SidebarItem: Hashable {
    case thisMac
}

struct ContentView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @ViewState private var selection: SidebarItem? = .thisMac

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
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
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            switch selection {
            case .thisMac, nil:
                MacDetailView()
            }
        }
    }
}
