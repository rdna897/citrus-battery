import AppKit
import CitrusKit
import SwiftUI

/// Identifies what an Advanced Viewer window shows: this Mac, or an iPhone/iPad by UDID.
enum AdvancedTarget {
    static let mac = "mac"
}

struct AdvancedViewer: View {
    let target: String
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var iosDevices: IOSDeviceMonitor

    @ViewState private var sections: [InfoNode] = []
    @ViewState private var loading = false
    @ViewState private var search = ""
    @ViewState private var selection = Set<InfoNode.ID>()
    /// Summary sections start open; raw battery registries start closed.
    @ViewState private var expanded: Set<InfoNode.ID> = ["Mac", "Storage", "Displays", "Device"]

    var body: some View {
        Group {
            if sections.isEmpty {
                VStack(spacing: 8) {
                    if loading {
                        ProgressView()
                        Text("Reading…").foregroundStyle(.secondary)
                    } else {
                        Text("No data. The device may be disconnected or locked.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { node in
                        NodeRow(node: node, expanded: $expanded, forceExpanded: !search.isEmpty)
                    }
                }
                .contextMenu(forSelectionType: InfoNode.ID.self) { ids in
                    Button("Copy Value") { copy(ids, mode: .value) }
                    Button("Copy Row") { copy(ids, mode: .row) }
                    Button("Copy Including Children (Tab-separated)") { copy(ids, mode: .subtree) }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter keys and values")
        .toolbar {
            Button {
                load()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(loading)
            Button {
                setPasteboard(sections.flatMap { $0.tabSeparated() }.joined(separator: "\n"))
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .help("Copy everything as tab-separated text")
            .disabled(sections.isEmpty)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: load)
    }

    private var title: String {
        if target == AdvancedTarget.mac {
            return "Advanced: \(monitor.marketingName ?? "This Mac")"
        }
        return "Advanced: \(iosDevices.device(udid: target)?.displayName ?? "Device")"
    }

    private func load() {
        guard !loading else { return }
        loading = true
        if target == AdvancedTarget.mac {
            // Fast, and uses NSScreen, so build on the main thread.
            sections = AdvancedInfo.mac(info: monitor.macInfo, marketingName: monitor.marketingName)
            // Open each drive inside Storage too.
            expanded.formUnion(sections.first { $0.id == "Storage" }?.children?.map(\.id) ?? [])
            loading = false
            return
        }
        let listing = iosDevices.device(udid: target).flatMap { device in
            device.connection.map { IOSDeviceReader.Listing(udid: device.udid, connection: $0) }
        }
        guard let listing else {
            loading = false
            return
        }
        Task.detached(priority: .userInitiated) {
            let raw = IOSDeviceReader.readRaw(listing)
            let built = raw.map { AdvancedInfo.device(info: $0.info, battery: $0.battery, pack: $0.pack) } ?? []
            await MainActor.run {
                sections = built
                loading = false
            }
        }
    }

    // MARK: Filtering and copying

    private var filtered: [InfoNode] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { filter($0, query) }
    }

    /// Keeps nodes that match, and ancestors of matches, so results stay in context.
    private func filter(_ node: InfoNode, _ query: String) -> InfoNode? {
        let matches = node.title.localizedCaseInsensitiveContains(query)
            || (node.value?.localizedCaseInsensitiveContains(query) ?? false)
        if matches { return node }
        let children = (node.children ?? []).compactMap { filter($0, query) }
        guard !children.isEmpty else { return nil }
        var copy = node
        copy.children = children
        return copy
    }

    private enum CopyMode { case value, row, subtree }

    private func copy(_ ids: Set<InfoNode.ID>, mode: CopyMode) {
        let nodes = flatten(sections).filter { ids.contains($0.id) }
        let text = nodes.flatMap { node -> [String] in
            switch mode {
            case .value: [node.value ?? ""]
            case .row: ["\(node.title)\t\(node.value ?? "")"]
            case .subtree: node.tabSeparated()
            }
        }
        setPasteboard(text.joined(separator: "\n"))
    }

    private func flatten(_ nodes: [InfoNode]) -> [InfoNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    private func setPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One row; rows with children become disclosure groups.
private struct NodeRow: View {
    let node: InfoNode
    @Binding var expanded: Set<InfoNode.ID>
    let forceExpanded: Bool

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: Binding(
                get: { forceExpanded || expanded.contains(node.id) },
                set: { open in
                    if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                }
            )) {
                ForEach(children) { child in
                    NodeRow(node: child, expanded: $expanded, forceExpanded: forceExpanded)
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(node.title)
            Spacer(minLength: 16)
            if let value = node.value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .help(node.value ?? "")
        .tag(node.id)
    }
}

/// "Advanced…" toolbar button for a device page.
struct AdvancedViewerButton: View {
    let target: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "advanced", value: target)
        } label: {
            Label("Advanced…", systemImage: "list.bullet.indent")
        }
        .help("Show every value the battery and device report")
    }
}
