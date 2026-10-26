import CitrusKit
import Combine
import SQLite3
import Foundation
import Testing
@testable import CitrusBattery

@Suite @MainActor struct HistoryControllerTests {
    static let date = Date(timeIntervalSince1970: 1_792_000_000)

    static func entry(_ serial: String) -> HistoryEntry {
        HistoryEntry(date: date, deviceType: .mac, deviceSerial: serial, deviceName: serial, deviceModel: "Mac")
    }

    static func controller(store: HistoryStore) -> (HistoryController, BatteryMonitor, IOSDeviceMonitor) {
        let monitor = BatteryMonitor(sampleBattery: MacBatterySnapshot(registry: [:], smc: nil, powerSource: nil, date: Self.date),
                                     info: MacInfo(modelIdentifier: "Mac", serialNumber: "M", osVersion: "13.0"),
                                     name: "Mac", power: PowerReadings(systemWatts: 8), history: [], limit: ChargeLimitStatus())
        let devices = IOSDeviceMonitor(sampleDevices: [])
        return (HistoryController(monitor: monitor, iosDevices: devices, store: store), monitor, devices)
    }

    /// Queue results reach the main actor before the next round. Initial loads
    /// schedule further reads, so drain their short chain as well.
    static func settle(_ store: HistoryStore) async {
        for _ in 0..<6 {
            await withCheckedContinuation { continuation in
                store.enqueue({ _ in () }) { _ in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
    }

    static func pause(_ store: HistoryStore) -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        store.enqueue({ _ in _ = release.wait(timeout: .now() + 5) }) { _ in }
        return release
    }

    @Test func switchingDevicesClearsRowsAndRejectsActionsUntilLoaded() async throws {
        let store = try HistoryStore(url: nil)
        try store.setAutoRecord(false, deviceSerial: "M")
        try store.insert(Self.entry("A"))
        try store.insert(Self.entry("B"))
        let (history, monitor, devices) = Self.controller(store: store)
        defer { withExtendedLifetime((monitor, devices)) {} }
        await Self.settle(store)
        history.selectedDeviceSerial = "A"
        await Self.settle(store)
        let ids = Set(history.entries.map(\.id))
        #expect(history.entriesLoaded && ids.count == 1)
        let release = Self.pause(store)
        history.selectedDeviceSerial = "B"
        #expect(history.entries.isEmpty && !history.entriesLoaded)
        history.delete(ids: ids)
        history.deleteAllForSelectedDevice()
        // A stale completion from B must not enable actions for A.
        history.selectedDeviceSerial = "A"
        #expect(history.entries.isEmpty && !history.entriesLoaded)
        release.signal()
        await Self.settle(store)
        #expect(history.entriesLoaded && history.entries.map(\.deviceSerial) == ["A"])
        #expect(try store.entries(deviceSerial: "B").count == 1)
        #expect(try store.entries(deviceSerial: "A").count == 1)
    }

    @Test func deletingADeviceKeepsANewerSelection() async throws {
        let store = try HistoryStore(url: nil)
        try store.setAutoRecord(false, deviceSerial: "M")
        try store.insert(Self.entry("A"))
        try store.insert(Self.entry("B"))
        let (history, monitor, devices) = Self.controller(store: store)
        defer { withExtendedLifetime((monitor, devices)) {} }
        await Self.settle(store)
        history.selectedDeviceSerial = "A"
        await Self.settle(store)
        let release = Self.pause(store)
        history.deleteAllForSelectedDevice()
        history.selectedDeviceSerial = "B"
        release.signal()
        await Self.settle(store)
        #expect(history.selectedDeviceSerial == "B")
        #expect(history.entriesLoaded && history.entries.map(\.deviceSerial) == ["B"])
        #expect(try store.entries(deviceSerial: "A").isEmpty)
    }

    @Test func pendingAutoRecordChangesAreVisibleAndSavedInOrder() async throws {
        let store = try HistoryStore(url: nil)
        try store.setAutoRecord(false, deviceSerial: "M")
        try store.insert(Self.entry("M"))
        let (history, monitor, devices) = Self.controller(store: store)
        defer { withExtendedLifetime((monitor, devices)) {} }
        await Self.settle(store)
        let release = Self.pause(store)
        history.setAutoRecord(true, for: "M")
        #expect(history.autoRecord(for: "M"))
        history.setAutoRecord(false, for: "M")
        #expect(!history.autoRecord(for: "M"))
        history.setAutoRecord(true, for: "M")
        #expect(history.autoRecord(for: "M"))
        release.signal()
        await Self.settle(store)
        #expect(history.autoRecord(for: "M"))
        #expect(try store.autoRecord(deviceSerial: "M") == true)
    }

    @Test(arguments: [false, true]) func skippedAutoRecordDoesNotReloadDevices(enabled: Bool) async throws {
        let store = try HistoryStore(url: nil)
        try store.setAutoRecord(enabled, deviceSerial: "M")
        try store.insert(Self.entry("M"))
        let (history, monitor, devices) = Self.controller(store: store)
        defer { withExtendedLifetime((monitor, devices)) {} }
        var updates = 0
        let observer = history.$devices.dropFirst().sink { _ in updates += 1 }
        await Self.settle(store)
        #expect(updates == 1)
        #expect(try store.entries(deviceSerial: "M").count == 1)
        withExtendedLifetime(observer) {}
    }

    @Test func failedToggleRestoresTheSavedValue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toggle-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try store.setAutoRecord(false, deviceSerial: "M")
        try store.insert(Self.entry("M"))
        let (history, monitor, devices) = Self.controller(store: store)
        defer { withExtendedLifetime((monitor, devices)) {} }
        await Self.settle(store)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "DROP TABLE devices", nil, nil, nil) == SQLITE_OK)
        history.setAutoRecord(true, for: "M")
        #expect(history.autoRecord(for: "M"))
        await Self.settle(store)
        #expect(!history.autoRecord(for: "M"))
        #expect(history.lastError != nil)
    }

    @Test func saveNowDoesNotRepeatAnUnchangedReading() async throws {
        let store = try HistoryStore(url: nil)
        try store.setAutoRecord(false, deviceSerial: "M")
        let (history, monitor, devices) = Self.controller(store: store)
        defer { withExtendedLifetime((monitor, devices)) {} }
        await Self.settle(store)
        history.saveNow()
        history.saveNow()
        await Self.settle(store)
        #expect(try store.entries(deviceSerial: "M").count == 1)
    }
}

@Suite @MainActor struct HistoryChartCacheTests {
    @Test func sameMinuteReplacementUpdatesTheChartAndSummary() {
        let cache = HistoryChartCache()
        let now = Date(timeIntervalSince1970: 1_792_000_080)
        var minutes = [PowerMinute(start: now - 60, averageWatts: 3, peakWatts: 5, chargePercent: 80, onAdapter: false)]
        let original = cache.data(period: .hour, minutes: minutes, sleeps: [], now: now)
        #expect(original.bars.first?.watts == 3 && cache.summary.average == 3)
        PowerTimeline.record(PowerMinute(start: minutes[0].start, averageWatts: 7, peakWatts: 9,
                                         chargePercent: 79, onAdapter: true), in: &minutes)
        let replaced = cache.data(period: .hour, minutes: minutes, sleeps: [], now: now)
        #expect(minutes.count == 1)
        #expect(replaced.bars.first?.watts == 7 && cache.summary.average == 7 && cache.summary.peak == 9)
        #expect(replaced.bars.first?.chargePercent == 79 && replaced.bars.first?.onAdapter == true)
    }
}
