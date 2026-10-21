import Charts
import CitrusKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryController
    @AppStorage(PreferenceKey.capacityUnit) private var capacityUnit = CapacityUnit.milliampHours

    @ViewState private var selection = Set<HistoryEntry.ID>()
    @ViewState private var sortOrder = [KeyPathComparator(\HistoryEntry.date, order: .reverse)]
    @ViewState private var confirmingDelete = false
    @ViewState private var confirmingDeleteAll = false
    @ViewState private var exporting = false
    @ViewState private var exportDocument = BackupDocument(data: Data())
    @ViewState private var importing = false
    @ViewState private var importMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            if history.entries.isEmpty {
                emptyState
            } else {
                chart
                    .padding(16)
                    .frame(height: 180)
                Divider()
                table
            }
        }
        .navigationTitle("History")
        .toolbar { toolbar }
        .confirmationDialog(
            "Delete \(selection.count) entr\(selection.count == 1 ? "y" : "ies") from your history?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                history.delete(ids: selection)
                selection.removeAll()
            }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Delete the complete history for \(selectedDevice?.name ?? "this device")?",
                            isPresented: $confirmingDeleteAll) {
            Button("Delete All", role: .destructive) { history.deleteAllForSelectedDevice() }
        } message: {
            Text("This can't be undone.")
        }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .json, defaultFilename: "Citrus Battery History") { result in
            if case let .failure(error) = result { history.reportError(error.localizedDescription) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    let added = history.importBackup(data)
                    importMessage = "Imported \(added) entr\(added == 1 ? "y" : "ies")."
                }
            case let .failure(error):
                history.reportError(error.localizedDescription)
            }
        }
        .alert("History", isPresented: Binding(get: { importMessage != nil || history.lastError != nil },
                                               set: { if !$0 { importMessage = nil; history.clearError() } })) {
            Button("OK") {}
        } message: {
            Text(history.lastError ?? importMessage ?? "")
        }
    }

    private var selectedDevice: HistoryDevice? {
        history.devices.first { $0.serial == history.selectedDeviceSerial }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Picker("Device", selection: $history.selectedDeviceSerial) {
                if history.devices.isEmpty {
                    Text("No devices").tag(String?.none)
                }
                ForEach(history.devices) { device in
                    Text("\(device.name) (\(device.entryCount))").tag(Optional(device.serial))
                }
            }
            .frame(maxWidth: 320)

            if let device = selectedDevice {
                Toggle("SmartSave", isOn: Binding(
                    get: { history.smartSave(for: device.serial) },
                    set: { history.setSmartSave($0, for: device.serial) }
                ))
                .help("Automatically save this device's battery data, at most once an hour and only when it has changed.")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(device.model).font(.caption)
                    Text(device.serial).font(.caption.monospaced()).textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
            } else {
                Spacer()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No history yet")
                .font(.headline)
            Text("SmartSave records this Mac's battery about once an hour when something has changed. "
                + "Use Save Now to record a reading immediately.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Save Now") { history.saveNow() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chart

    private var chart: some View {
        let points = history.entries.compactMap { entry in
            entry.healthFraction.map { (date: entry.date, health: $0 * 100) }
        }
        let low = max((points.map(\.health).min() ?? 80) - 5, 0)
        let high = max(points.map(\.health).max() ?? 100, 100) + 2
        return Chart(points, id: \.date) { point in
            LineMark(x: .value("Date", point.date), y: .value("Health", point.health))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Date", point.date), y: .value("Health", point.health))
                .symbolSize(18)
        }
        .chartYScale(domain: low...high)
        .chartYAxisLabel("Health %")
    }

    // MARK: Table

    private var sortedEntries: [HistoryEntry] {
        history.entries.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(sortedEntries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.date) { entry in
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 140, ideal: 160)
            TableColumn("Cycles", value: \.cycleCountSortKey) { entry in
                Text(entry.cycleCount.map(String.init) ?? "—").monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Health", value: \.healthSortKey) { entry in
                Text(entry.healthFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "—").monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Full Charge", value: \.fullChargeSortKey) { entry in
                Text(entry.fullChargeCapacity.map { capacityUnit.format(milliampHours: $0, voltageMillivolts: nil) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 90)
            TableColumn("Design", value: \.designSortKey) { entry in
                Text(entry.designCapacity.map { capacityUnit.format(milliampHours: $0, voltageMillivolts: nil) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 90)
            TableColumn("Battery Serial", value: \.batterySerialSortKey) { entry in
                Text(entry.batterySerial ?? "—").textSelection(.enabled)
            }
            TableColumn("OS", value: \.osSortKey) { entry in
                Text(entry.osVersion ?? "—")
            }
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            Button("Copy") { copy(ids) }
            Button("Delete…", role: .destructive) {
                selection = ids
                confirmingDelete = true
            }
        }
    }

    private func copy(_ ids: Set<HistoryEntry.ID>) {
        let rows = sortedEntries.filter { ids.contains($0.id) }.map { entry in
            [entry.date.formatted(date: .numeric, time: .shortened),
             entry.cycleCount.map(String.init) ?? "",
             entry.healthFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "",
             entry.fullChargeCapacity.map(String.init) ?? "",
             entry.designCapacity.map(String.init) ?? "",
             entry.batterySerial ?? "",
             entry.osVersion ?? ""].joined(separator: "\t")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.joined(separator: "\n"), forType: .string)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                history.saveNow()
            } label: {
                Label("Save Now", systemImage: "plus")
            }
            .help("Save the current battery reading")

            Button {
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "minus")
            }
            .disabled(selection.isEmpty)
            .help("Delete the selected entries")

            Menu {
                Button("Create Backup…") {
                    guard let data = history.exportBackup() else { return }
                    exportDocument = BackupDocument(data: data)
                    exporting = true
                }
                Button("Import Backup…") { importing = true }
                Divider()
                Button("Delete All History for This Device…", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(selectedDevice == nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Sort keys that put missing values first.
extension HistoryEntry {
    var cycleCountSortKey: Int { cycleCount ?? -1 }
    var healthSortKey: Double { healthFraction ?? -1 }
    var fullChargeSortKey: Int { fullChargeCapacity ?? -1 }
    var designSortKey: Int { designCapacity ?? -1 }
    var batterySerialSortKey: String { batterySerial ?? "" }
    var osSortKey: String { osVersion ?? "" }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
