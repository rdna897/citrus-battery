import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import CitrusKit

struct FakeSMC: SMCReading {
    var values: [String: SMCValue]
    func read(_ key: String) -> SMCValue? { values[key] }
}

@Suite struct SMCValueTests {
    @Test func littleEndianIntegersOnAppleSilicon() {
        // B0CT read from an M4 MacBook Air: 0x2e00 = 46 cycles.
        let cycles = SMCValue(type: "ui16", bytes: [0x2E, 0x00])
        #expect(cycles.doubleValue(littleEndianIntegers: true) == 46)
        #expect(cycles.doubleValue(littleEndianIntegers: false) == 11776)
    }

    @Test func signedCurrent() {
        let current = SMCValue(type: "si16", bytes: [0x18, 0xFC]) // -1000 mA little-endian
        #expect(current.doubleValue(littleEndianIntegers: true) == -1000)
    }

    @Test func float() {
        // TB0T on the same Mac: 28.2 °C.
        let temperature = SMCValue(type: "flt ", bytes: [0x98, 0x99, 0xE1, 0x41])
        #expect(abs((temperature.doubleValue() ?? 0) - 28.2) < 0.01)
    }

    @Test func intelFixedPoint() {
        #expect(SMCValue(type: "sp78", bytes: [0x1C, 0x80]).doubleValue() == 28.5)
        #expect(SMCValue(type: "fpe2", bytes: [0x00, 0x0A]).doubleValue() == 2.5)
    }
}

@Suite struct BatteryFailureTests {
    @Test func bitMap() {
        let failures = BatteryFailure(rawValue: 1 << 0 | 1 << 4 | 1 << 15)
        #expect(failures.messages == ["External Input Problem", "Cell Imbalance", "Fuse Blown"])
        #expect(BatteryFailure(rawValue: 0).messages.isEmpty)
    }
}

@Suite struct UnitTests {
    @Test func temperatureScales() {
        #expect(TemperatureUnit.fahrenheit.convert(celsius: 100) == 212)
        #expect(TemperatureUnit.kelvin.convert(celsius: 0) == 273.15)
        #expect(TemperatureUnit.delisle.convert(celsius: 100) == 0)
        #expect(TemperatureUnit.newton.convert(celsius: 100) == 33)
        #expect(TemperatureUnit.reaumur.convert(celsius: 100) == 80)
        #expect(TemperatureUnit.romer.convert(celsius: 100) == 60)
        #expect(abs(TemperatureUnit.rankine.convert(celsius: 0) - 491.67) < 0.001)
    }

    @Test func wattHours() {
        #expect(CapacityUnit.wattHours.format(milliampHours: 4556, voltageMillivolts: 11524) == "52.5 Wh")
        #expect(CapacityUnit.milliampHours.format(milliampHours: 4556, voltageMillivolts: 11524) == "4556 mAh")
    }
}

@Suite struct SnapshotTests {
    /// Abbreviated `AppleSmartBattery` properties from an M4 MacBook Air (macOS 27).
    nonisolated(unsafe) static let appleSilicon: [String: Any] = [
        "CurrentCapacity": 22, "MaxCapacity": 100, "CycleCount": 46, "DesignCycleCount9C": 1000,
        "Voltage": 11524, "InstantAmperage": 1055, "IsCharging": true, "ExternalConnected": true,
        "FullyCharged": false, "AvgTimeToEmpty": 65535, "AvgTimeToFull": 269,
        "Serial": "F8YHK2000630000G43", "DeviceName": "bq40z651",
        "AdapterDetails": ["Watts": 20, "Description": "pd charger", "AdapterVoltage": 12000, "Current": 1670],
        "BatteryData": [
            "DesignCapacity": 4629, "FullChargeCapacity": 4556, "NominalChargeCapacity": 4683,
            "RemainingCapacity": 973,
        ],
    ]

    @Test func appleSiliconLayoutUsesBatteryDataAndSMCTemperature() {
        let smc = FakeSMC(values: ["TB0T": SMCValue(type: "flt ", bytes: [0x98, 0x99, 0xE1, 0x41])])
        let snapshot = MacBatterySnapshot(registry: Self.appleSilicon, smc: smc, powerSource: nil)

        #expect(snapshot.designCapacity == 4629)
        #expect(snapshot.fullChargeCapacity == 4556)
        #expect(snapshot.currentCapacity == 973)
        #expect(snapshot.cycleCount == 46)
        #expect(snapshot.timeToEmptyMinutes == nil)
        #expect(snapshot.timeToFullMinutes == 269)
        #expect(snapshot.adapter?.watts == 20)
        #expect(abs((snapshot.temperatureCelsius ?? 0) - 28.2) < 0.01)
        #expect(abs((snapshot.healthFraction ?? 0) - 0.9842) < 0.001)
        #expect(abs((snapshot.batteryPowerWatts ?? 0) - 12.158) < 0.01)
    }

    @Test func intelLayoutUsesTopLevelValues() {
        let intel: [String: Any] = [
            "CurrentCapacity": 3000, "MaxCapacity": 5000, "DesignCapacity": 6000,
            "AppleRawCurrentCapacity": 3100, "AppleRawMaxCapacity": 5100,
            "Temperature": 3050, "CycleCount": 300, "Voltage": 12000,
            "InstantAmperage": NSNumber(value: UInt64.max - 999), // −1000 mA as stored by IOKit
            "IsCharging": false, "ExternalConnected": false,
            "ManufactureDate": (2019 - 1980) << 9 | 7 << 5 | 14,
            "PermanentFailureStatus": 1 << 12,
        ]
        let snapshot = MacBatterySnapshot(registry: intel, smc: nil, powerSource: nil)

        #expect(snapshot.currentCapacity == 3100)
        #expect(snapshot.fullChargeCapacity == 5100)
        #expect(snapshot.designCapacity == 6000)
        #expect(snapshot.temperatureCelsius == 30.5)
        #expect(snapshot.amperageMilliamps == -1000)
        #expect(snapshot.batteryPowerWatts == -12)
        #expect(snapshot.manufactureDate == DateComponents(year: 2019, month: 7, day: 14))
        #expect(snapshot.failures == .openThermistor)
    }

    @Test func appleStylePrefersMacOSPercentage() {
        let snapshot = MacBatterySnapshot(
            registry: Self.appleSilicon, smc: nil,
            powerSource: PowerSourceInfo(chargePercent: 22)
        )
        #expect(snapshot.chargeFraction(style: .apple) == 0.22)
        #expect(abs((snapshot.chargeFraction(style: .raw) ?? 0) - 973.0 / 4556) < 0.0001)
    }

    @Test func timeRemainingPrefersMacOSAndFallsBackToTheBattery() {
        let macOS = MacBatterySnapshot(registry: Self.appleSilicon, smc: nil,
                                       powerSource: PowerSourceInfo(timeToFullMinutes: 95))
        #expect(macOS.timeRemainingMinutes == 95)
        let battery = MacBatterySnapshot(registry: Self.appleSilicon, smc: nil, powerSource: PowerSourceInfo())
        #expect(battery.timeRemainingMinutes == 269)
        #expect(!battery.isCalculatingTimeRemaining)
    }

    @Test func calculatingHidesTheBatteryAverage() {
        let charging = MacBatterySnapshot(registry: Self.appleSilicon, smc: nil,
                                          powerSource: PowerSourceInfo(isCalculatingTimeToFull: true))
        #expect(charging.isCalculatingTimeRemaining)
        #expect(charging.timeRemainingMinutes == nil)

        var unplugged = Self.appleSilicon
        unplugged["IsCharging"] = false
        unplugged["ExternalConnected"] = false
        unplugged["AvgTimeToEmpty"] = 300
        let discharging = MacBatterySnapshot(registry: unplugged, smc: nil,
                                             powerSource: PowerSourceInfo(isCalculatingTimeToEmpty: true))
        #expect(discharging.isCalculatingTimeRemaining)
        #expect(discharging.timeRemainingMinutes == nil)
        // Only the estimate for the current direction counts.
        let other = MacBatterySnapshot(registry: unplugged, smc: nil,
                                       powerSource: PowerSourceInfo(isCalculatingTimeToFull: true))
        #expect(!other.isCalculatingTimeRemaining)
        #expect(other.timeRemainingMinutes == 300)
    }
}

@Suite struct BatteryOriginTests {
    @Test func manufacturerFromSerialPrefix() {
        #expect(BatteryOrigin.manufacturer(serial: "F8YHK2000630000G43") == "Sunwoda")
        #expect(BatteryOrigin.manufacturer(serial: "d865033y2acf9cbaz") == "Simplo Technology")
        #expect(BatteryOrigin.manufacturer(serial: "QQ123") == nil)
        #expect(BatteryOrigin.manufacturer(serial: "F") == nil)
    }

    @Test func manufactureWeek() {
        #expect(BatteryOrigin.manufactureWeek(bmdt: "330802") == .init(week: 33, month: 8))
        #expect(BatteryOrigin.manufactureWeek(bmdt: "991302") == nil)
        #expect(BatteryOrigin.manufactureWeek(bmdt: "") == nil)
    }

    @Test func snapshotUsesSMCSerialAndWeek() {
        let smc = FakeSMC(values: [
            "BMSN": SMCValue(type: "ch8*", bytes: Array("F8YHK2000630000G43".utf8) + [0, 0, 0]),
            "BMDT": SMCValue(type: "ch8*", bytes: Array("330802".utf8) + [0]),
        ])
        let snapshot = MacBatterySnapshot(registry: ["BatteryData": [String: Any]()], smc: smc, powerSource: nil)
        #expect(snapshot.serialNumber == "F8YHK2000630000G43")
        #expect(snapshot.manufacturer == "Sunwoda")
        #expect(snapshot.manufactureDate == nil)
        #expect(snapshot.manufactureWeek == .init(week: 33, month: 8))
    }
}

@Suite struct ManufactureDateTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test func asciiManufactureDate() {
        // Apple Silicon pack value: bytes "208033" little-endian → "330802".
        #expect(MacBatterySnapshot.asciiDigits(55182682501939) == "330802")
        #expect(MacBatterySnapshot.asciiDigits(0x5B0B) == nil)
        #expect(MacBatterySnapshot.decodePackedDate(55182682501939) == nil)
    }

    @Test func estimateFromOperatingHours() {
        // M4 MacBook Air, 2026-10-19: 10,424 operating hours, recorded week 33.
        let now = Self.day(2026, 10, 19)
        let withWeek = BatteryOrigin.estimatedManufactureDate(
            operatingHours: 10_424, week: .init(week: 33, month: 8), now: now, calendar: Self.utc)
        #expect(withWeek.map { Self.utc.dateComponents([.year, .month, .day], from: $0) }
            == DateComponents(year: 2025, month: 8, day: 11))

        let withoutWeek = BatteryOrigin.estimatedManufactureDate(
            operatingHours: 10_424, week: nil, now: now, calendar: Self.utc)
        #expect(withoutWeek.map { Self.utc.dateComponents([.year, .month, .day], from: $0) }
            == DateComponents(year: 2025, month: 8, day: 11))
    }

    @Test func packSuppliesLifetimeTemperatureAndDate() {
        let pack: [String: Any] = [
            "Temperature": 2579, "ManufactureDate": 55182682501939,
            "LifetimeData": ["TotalOperatingTime": 10_424, "MaximumTemperature": 38, "MinimumTemperature": 6,
                             "AverageTemperature": 212, "MaximumPackVoltage": 13368, "MinimumPackVoltage": 10676],
        ]
        let snapshot = MacBatterySnapshot(registry: SnapshotTests.appleSilicon, pack: pack, smc: nil,
                                          powerSource: nil, date: Self.day(2026, 10, 19))
        #expect(snapshot.temperatureCelsius == 25.79)
        #expect(snapshot.manufactureWeek == .init(week: 33, month: 8))
        #expect(snapshot.lifetime?.totalOperatingHours == 10_424)
        #expect(snapshot.lifetime?.averageTemperatureCelsius == 21.2)
        #expect(snapshot.estimatedManufactureDate != nil)
    }
}

@Suite struct SerialManufactureDateTests {
    static func ymd(_ date: Date?) -> DateComponents? {
        date.map { ManufactureDateTests.utc.dateComponents([.year, .month, .day], from: $0) }
    }

    let now = ManufactureDateTests.day(2026, 10, 21)

    @Test func usesFixedTableWithoutEstimate() {
        // Digit 9 → 2019, week 41 → Monday 7 October.
        #expect(Self.ymd(BatteryOrigin.serialManufactureDate(serial: "D869414A9LHKLHVAG", now: now))
            == DateComponents(year: 2019, month: 10, day: 7))
        // Digit 3 → 2023, or 2013 for a well-used pack.
        #expect(Self.ymd(BatteryOrigin.serialManufactureDate(serial: "ABC3100000000000X", cycleCount: 12, now: now))
            == DateComponents(year: 2023, month: 3, day: 6))
        #expect(Self.ymd(BatteryOrigin.serialManufactureDate(serial: "ABC3100000000000X", cycleCount: 450, now: now))
            == DateComponents(year: 2013, month: 3, day: 4))
        // A date in the future moves back a decade.
        #expect(Self.ymd(BatteryOrigin.serialManufactureDate(
            serial: "ABC2100000000000X", now: ManufactureDateTests.day(2021, 1, 1)))
            == DateComponents(year: 2012, month: 3, day: 5))
    }

    @Test func operatingTimeEstimatePicksTheDecade() {
        // The fixed table would say 2014; the estimate says this decade.
        let estimate = ManufactureDateTests.day(2024, 2, 20)
        #expect(Self.ymd(BatteryOrigin.serialManufactureDate(serial: "ABC4100000000000X", estimate: estimate, now: now))
            == DateComponents(year: 2024, month: 3, day: 4))
    }

    @Test func rejectsOtherFormats() {
        #expect(BatteryOrigin.serialManufactureDate(serial: "F8YHK2000630000G43", now: now) == nil)  // 18 chars
        #expect(BatteryOrigin.serialManufactureDate(serial: "ABCX100000000000X", now: now) == nil)  // no digit
        #expect(BatteryOrigin.serialManufactureDate(serial: "ABC9600000000000X", now: now) == nil)  // week 60
    }
}

@Suite struct LifetimeReportTests {
    @Test func listsLifetimeValues() {
        var registry = SnapshotTests.appleSilicon
        registry["LifetimeData"] = ["TotalOperatingTime": 10_465, "MaximumTemperature": 38, "MinimumTemperature": 6,
                                    "AverageTemperature": 212, "MaximumChargeCurrent": 5400,
                                    "MaximumDischargeCurrent": -3140, "TemperatureSamples": 167_440,
                                    "CycleCountLastQmax": 40, "UpdateTime": 1_792_583_594]
        let snapshot = MacBatterySnapshot(registry: registry, pack: [:], smc: nil, powerSource: nil,
                                          date: ManufactureDateTests.day(2026, 10, 21))
        let rows = LifetimeReport.rows(for: snapshot, temperatureUnit: .celsius)
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.value) })
        #expect(values["Minimum temperature"] == "6.0°C")
        #expect(values["Average temperature"] == "21.2°C")
        #expect(values["Battery failures"] == "None")
        #expect(values["Maximum discharge current"]?.hasPrefix("3140 mA (") == true)
        #expect(values["Gauge last calibrated"]?.hasPrefix("At cycle 40") == true)
        #expect(values["Lifetime data updated"] != nil)
    }

    @Test func emptyWithoutLifetimeData() {
        let snapshot = MacBatterySnapshot(registry: SnapshotTests.appleSilicon, pack: [:], smc: nil,
                                          powerSource: nil, date: Date())
        #expect(LifetimeReport.rows(for: snapshot, temperatureUnit: .celsius).isEmpty)
    }
}

@Suite struct ChargeLimitTests {
    @Test func noLimitGivesNoAdvice() {
        #expect(ChargeLimitStatus(optimizedChargingEnabled: true).advice(cyclesSinceCalibration: 3) == nil)
        #expect(!ChargeLimitStatus(optimizedChargingEnabled: true).isLimiting)
    }

    @Test func macOSLimitIsReassuring() {
        let advice = ChargeLimitStatus(macOSLimitPercent: 95).advice(cyclesSinceCalibration: 6)
        #expect(advice?.level == .info)
        #expect(advice?.message.contains("occasionally charges to 100%") == true)
    }

    @Test func optimizedHoldIsReassuring() {
        let status = ChargeLimitStatus(optimizedChargingEnabled: true, optimizedChargingEngaged: true)
        #expect(status.isLimiting)
        #expect(status.advice(cyclesSinceCalibration: nil)?.level == .info)
    }

    @Test func thirdPartyLimiterWarnsAboutCalibration() {
        let advice = ChargeLimitStatus(macOSLimitPercent: 80, thirdPartyLimiters: ["AlDente"])
            .advice(cyclesSinceCalibration: 25)
        #expect(advice?.level == .caution)
        #expect(advice?.message.hasPrefix("AlDente is limiting") == true)
        #expect(advice?.message.contains("recalibrated 25 cycles ago") == true)
    }

    @Test func firmwareLevelLimitCountsAsThirdParty() {
        let status = ChargeLimitStatus(smcChargeLevelLimit: 60)
        #expect(status.hasThirdPartyLimit)
        #expect(status.advice(cyclesSinceCalibration: nil)?.message.hasPrefix("Another app is") == true)
    }

    @Test func cyclesSinceCalibration() {
        let pack: [String: Any] = ["LifetimeData": ["CycleCountLastQmax": 40]]
        let snapshot = MacBatterySnapshot(registry: SnapshotTests.appleSilicon, pack: pack, smc: nil, powerSource: nil)
        #expect(snapshot.cyclesSinceCalibration == 6)
    }
}

@Suite struct HistoryTests {
    static func entry(_ day: Int, hour: Int = 12, cycles: Int = 46, fcc: Int = 4500,
                      serial: String = "MAC1") -> HistoryEntry {
        let date = ManufactureDateTests.utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        return HistoryEntry(date: date, deviceType: .mac, deviceSerial: serial, deviceName: "MacBook Air",
                            deviceModel: "Mac16,12", osVersion: "27.0", batterySerial: "F8Y",
                            cycleCount: cycles, designCapacity: 4629, fullChargeCapacity: fcc)
    }

    @Test func roundTripAndOrdering() throws {
        let store = try HistoryStore(url: nil)
        try store.insert(Self.entry(19))
        try store.insert(Self.entry(20, cycles: 47))
        let entries = try store.entries(deviceSerial: "MAC1")
        #expect(entries.count == 2)
        #expect(entries.first?.cycleCount == 47) // newest first
        #expect(entries.first?.batterySerial == "F8Y")
        #expect(abs((entries.first?.healthFraction ?? 0) - 4500.0 / 4629) < 0.0001)
    }

    @Test func renamesLegacyDeviceColumn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE devices (serial TEXT PRIMARY KEY, smart_save INTEGER NOT NULL);"
            + "INSERT INTO devices VALUES ('MAC1', 0);", nil, nil, nil)
        sqlite3_close(db)

        let store = try HistoryStore(url: url)
        try #expect(store.autoRecord(deviceSerial: "MAC1") == false)
    }

    @Test func devicesAndAutoRecord() throws {
        let store = try HistoryStore(url: nil)
        try store.insert(Self.entry(19))
        try store.insert(Self.entry(20))
        try store.insert(Self.entry(18, serial: "PHONE"))
        var devices = try store.devices(defaultAutoRecord: true)
        #expect(devices.map(\.serial) == ["MAC1", "PHONE"])
        #expect(devices.first?.entryCount == 2)
        let allAutoRecord = devices.allSatisfy(\.autoRecord)
        #expect(allAutoRecord)

        try #expect(store.autoRecord(deviceSerial: "MAC1") == nil)
        try store.setAutoRecord(false, deviceSerial: "MAC1")
        try #expect(store.autoRecord(deviceSerial: "MAC1") == false)
        devices = try store.devices(defaultAutoRecord: true)
        #expect(devices.first?.autoRecord == false)
    }

    @Test func deleteEntriesAndDevice() throws {
        let store = try HistoryStore(url: nil)
        let first = try store.insert(Self.entry(19))
        try store.insert(Self.entry(20))
        try store.delete(ids: [first])
        try #expect(store.entries().count == 1)
        try store.deleteAll(deviceSerial: "MAC1")
        try #expect(store.entries().isEmpty)
    }

    @Test func backupRoundTripSkipsDuplicates() throws {
        let source = try HistoryStore(url: nil)
        try source.insert(Self.entry(19))
        try source.insert(Self.entry(20, cycles: 47))
        let backup = try source.exportBackup()

        let target = try HistoryStore(url: nil)
        try target.insert(Self.entry(19))
        try #expect(target.importBackup(backup).entries == 1)
        try #expect(target.entries().count == 2)
        try #expect(target.importBackup(backup).entries == 0)
        #expect(throws: HistoryError.self) { try target.importBackup(Data("{}".utf8)) }
    }

    @Test func backupCarriesSleepSessionsAndWakes() throws {
        let night = Date(timeIntervalSince1970: 1_792_000_000)
        let session = SleepSession(start: night, end: night + 8 * 3600, startCapacity: 4000, endCapacity: 3900,
                                   fullChargeCapacity: 4500, briefWakes: 2, wakesLogged: true)
        let source = try HistoryStore(url: nil)
        try source.insert(session)
        try source.insert([DarkWake(date: night + 600, reason: .scheduledTask, detail: "com.apple.x", seconds: 7,
                                    holders: ["cloudd", "powerd"], apps: ["com.apple.Photos"]),
                           DarkWake(date: night + 1200, reason: .wireless)], loggedSessions: [])
        let backup = try source.exportBackup()

        let target = try HistoryStore(url: nil)
        #expect(try target.importBackup(backup) == HistoryStore.BackupImport(entries: 0, sleepSessions: 1))
        let restored = try #require(try target.sleepSessions().first)
        #expect(restored.start == night && restored.briefWakes == 2 && restored.wakesLogged)
        #expect(try target.darkWakes() == source.darkWakes())
        // Importing again adds nothing.
        #expect(try target.importBackup(backup) == HistoryStore.BackupImport(entries: 0, sleepSessions: 0))
        #expect(try target.darkWakes().count == 2)
        // Version 1 backups, with entries only, still import.
        let v1 = Data(#"{"format":"citrus-battery-history","version":1,"entries":[]}"#.utf8)
        #expect(try target.importBackup(v1) == HistoryStore.BackupImport(entries: 0, sleepSessions: 0))
        // Wakes from before durations, holders and apps were saved still import.
        let early = Data(#"""
            {"format":"citrus-battery-history","version":2,"entries":[],
             "darkWakes":[{"date":"2026-01-01T00:00:00Z","reason":"wireless"}]}
            """#.utf8)
        let fresh = try HistoryStore(url: nil)
        _ = try fresh.importBackup(early)
        #expect(try fresh.darkWakes().first?.holders == [])
    }

    @Test func damagedBackupsChangeNothing() throws {
        let store = try HistoryStore(url: nil)
        // A sleep ending before it starts, alongside a sound one.
        let damaged = Data(#"""
            {"format":"citrus-battery-history","version":2,
             "entries":[],
             "sleepSessions":[
                {"start":"2026-01-02T00:00:00Z","end":"2026-01-02T08:00:00Z","startCapacity":4000,"endCapacity":3900,
                 "fullChargeCapacity":4500},
                {"start":"2026-01-03T08:00:00Z","end":"2026-01-03T00:00:00Z","startCapacity":4000,"endCapacity":3900,
                 "fullChargeCapacity":4500,"wakesLogged":true}]}
            """#.utf8)
        #expect(throws: HistoryError.damagedBackup) { try store.importBackup(damaged) }
        // Not even the sound one was saved.
        #expect(try store.sleepSessions().isEmpty)
        let noCapacity = Data(#"""
            {"format":"citrus-battery-history","version":2,"entries":[],
             "sleepSessions":[{"start":"2026-01-02T00:00:00Z","end":"2026-01-02T08:00:00Z","startCapacity":4000,
                               "endCapacity":3900,"fullChargeCapacity":0}]}
            """#.utf8)
        #expect(throws: HistoryError.damagedBackup) { try store.importBackup(noCapacity) }
    }

    @Test func damagedSessionsAlreadySavedAreSkipped() throws {
        let store = try HistoryStore(url: nil)
        let night = Date(timeIntervalSince1970: 1_792_000_000)
        try store.insert(SleepSession(start: night, end: night - 3600, startCapacity: 4000, endCapacity: 3990,
                                      fullChargeCapacity: 4500, wakesLogged: true))
        try store.insert(SleepSession(start: night, end: night + 3600, startCapacity: 4000, endCapacity: 3990,
                                      fullChargeCapacity: 4500))
        #expect(try store.sleepSessions().count == 1)
        // And a damaged session reads as an instant rather than trapping.
        let backwards = SleepSession(start: night, end: night - 60, startCapacity: 1, endCapacity: 1,
                                     fullChargeCapacity: 1)
        #expect(backwards.interval.duration == 0)
    }

    @Test func sleepsFromAnotherMacStayApart() throws {
        let night = Date(timeIntervalSince1970: 1_792_000_000)
        func session(_ offset: TimeInterval, mac: String?) -> SleepSession {
            SleepSession(start: night + offset, end: night + offset + 3600, startCapacity: 4000, endCapacity: 3990,
                         fullChargeCapacity: 4500, mac: mac)
        }
        let old = try HistoryStore(url: nil)
        try old.insert(session(0, mac: "OLDMAC"))
        try old.insert([DarkWake(date: night + 60, reason: .wireless, mac: "OLDMAC")], loggedSessions: [])
        let backup = try old.exportBackup()

        let store = try HistoryStore(url: nil)
        // Saved before Macs were recorded, then claimed by the Mac running the app.
        try store.insert(session(86_400, mac: nil))
        try store.claimSleepData(for: "NEWMAC")
        #expect(try store.sleepSessions().map(\.mac) == ["NEWMAC"])
        // The old Mac's sleep at the same time as one of this Mac's is still its own.
        try store.insert(session(0, mac: "NEWMAC"))
        #expect(try store.importBackup(backup, mac: "NEWMAC").sleepSessions == 1)
        #expect(try store.sleepSessions(mac: "NEWMAC").count == 2)
        #expect(try store.sleepSessions(mac: "OLDMAC").count == 1)
        #expect(try store.darkWakes(mac: "NEWMAC").isEmpty)
        #expect(try store.darkWakes(mac: "OLDMAC").count == 1)
        // A backup from before Macs were recorded is taken to be this Mac's.
        let legacy = Data(#"""
            {"format":"citrus-battery-history","version":2,"entries":[],
             "sleepSessions":[{"start":"2026-01-02T00:00:00Z","end":"2026-01-02T08:00:00Z","startCapacity":4000,
                               "endCapacity":3900,"fullChargeCapacity":4500}]}
            """#.utf8)
        _ = try store.importBackup(legacy, mac: "NEWMAC")
        #expect(try store.sleepSessions(mac: "NEWMAC").count == 3)
    }

    @Test func importingANewerBackupAddsWhatItKnows() throws {
        let night = Date(timeIntervalSince1970: 1_792_000_000)
        let base = SleepSession(start: night, end: night + 3600, startCapacity: 4000, endCapacity: 3990,
                                fullChargeCapacity: 4500, mac: "M")
        let store = try HistoryStore(url: nil)
        try store.insert(base)
        try store.insert([DarkWake(date: night + 60, reason: .wireless, seconds: 5, apps: ["com.apple.Photos"],
                                   mac: "M")], loggedSessions: [])
        // A later backup of the same sleep, after the system log was read for it.
        let newer = try HistoryStore(url: nil)
        var read = base
        read.wakesLogged = true
        read.appsLogged = true
        read.briefWakes = 1
        try newer.insert(read)
        try newer.insert([DarkWake(date: night + 60, reason: .pushNotification, apps: ["com.apple.Notes"], mac: "M")],
                         loggedSessions: [])
        #expect(try store.importBackup(newer.exportBackup(), mac: "M").sleepSessions == 0)
        let session = try #require(try store.sleepSessions().first)
        #expect(session.wakesLogged && session.appsLogged && session.briefWakes == 1)
        let wake = try #require(try store.darkWakes().first)
        #expect(wake.reason == .pushNotification && wake.seconds == 5)
        #expect(wake.apps == ["com.apple.Photos", "com.apple.Notes"])
    }

    @Test func failedSystemLogReadsAreToldApart() throws {
        let night = Date(timeIntervalSince1970: 1_792_000_000)
        let store = try HistoryStore(url: nil)
        for offset in [0.0, 86_400] {
            try store.insert(SleepSession(start: night + offset, end: night + offset + 3600, startCapacity: 4000,
                                          endCapacity: 3990, fullChargeCapacity: 4500, wakesLogged: true))
        }
        let ids = try store.sleepSessions().map(\.id)
        try store.annotate([], loggedSessions: [ids[0]], failed: true)
        try store.annotate([], loggedSessions: [ids[1]])
        let sessions = try store.sleepSessions()
        // Both were tried, so neither is read again; only one is unknown rather than empty.
        #expect(sessions.allSatisfy { $0.appsLogged })
        #expect(sessions.map(\.appsReadFailed) == [true, false])
        // And a backup keeps the difference.
        let restored = try HistoryStore(url: nil)
        _ = try restored.importBackup(try store.exportBackup())
        #expect(try restored.sleepSessions().map(\.appsReadFailed) == [true, false])
    }

    @Test func wakesGainDetailsWithoutLosingThem() throws {
        let night = Date(timeIntervalSince1970: 1_792_000_000)
        let store = try HistoryStore(url: nil)
        try store.insert(SleepSession(start: night, end: night + 3600, startCapacity: 4000, endCapacity: 3990,
                                      fullChargeCapacity: 4500, wakesLogged: true))
        let id = try #require(try store.sleepSessions().first?.id)
        // Saved before durations were read, then read again.
        try store.insert([DarkWake(date: night + 60, reason: .wireless)], loggedSessions: [id])
        try store.insert([DarkWake(date: night + 60, reason: .wireless, seconds: 9, holders: ["cloudd"])],
                         loggedSessions: [id])
        #expect(try store.darkWakes() == [DarkWake(date: night + 60, reason: .wireless, seconds: 9,
                                                   holders: ["cloudd"])])
        try store.annotate([DarkWake(date: night + 60, reason: .pushNotification, seconds: 9, holders: ["cloudd"],
                                     apps: ["com.apple.Photos"])], loggedSessions: [id])
        #expect(try store.darkWakes().first?.reason == .pushNotification)
        #expect(try store.darkWakes().first?.apps == ["com.apple.Photos"])
        #expect(try store.sleepSessions().first?.appsLogged == true)
        // Reading the power log again doesn't undo the system log's additions.
        try store.insert([DarkWake(date: night + 60, reason: .wireless, seconds: 9, holders: ["cloudd"])],
                         loggedSessions: [id])
        #expect(try store.darkWakes().first?.reason == .pushNotification)
    }

    @Test func autoRecordDuplicateRule() {
        let calendar = ManufactureDateTests.utc
        let saved = [Self.entry(19, hour: 9)]
        // Same day, same cycles, capacity within 5% → duplicate.
        #expect(AutoRecordPolicy.isDuplicate(Self.entry(19, hour: 20, fcc: 4700), of: saved, calendar: calendar))
        // Capacity moved more than 5%.
        #expect(!AutoRecordPolicy.isDuplicate(Self.entry(19, hour: 20, fcc: 4200), of: saved, calendar: calendar))
        // New cycle.
        #expect(!AutoRecordPolicy.isDuplicate(Self.entry(19, hour: 20, cycles: 47), of: saved, calendar: calendar))
        // Next day.
        #expect(!AutoRecordPolicy.isDuplicate(Self.entry(20, hour: 9), of: saved, calendar: calendar))
    }
}

@Suite struct CoconutBatteryImportTests {
    /// Builds a backup in the `.ccba` format: JSON → LZFSE → AES-GCM.
    static func makeBackup(_ records: [[String: Any]], key: SymmetricKey) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: records)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data
        return try AES.GCM.seal(compressed, using: key).combined!
    }

    nonisolated(unsafe) static let record: [String: Any] = [
        "Data.Version": "4.0.0", "Data.Type": "Mac", "Data.SnapshotDate": 1760824767.598602,
        "Device.Serial": "MAC1", "Device.Name": "Test MacBook Air", "Device.Model": "Mac16,12",
        "Device.OSVersion": "26.0.1", "Battery.Serial": "F8Y", "Battery.CycleCount": 2,
        "Battery.DC": 4629, "Battery.FCC": 4641, "Battery.Raw": "ignored", "Device.Custom": "custom",
    ]

    @Test func decodesWithMatchingKeyAmongCandidates() throws {
        let key = SymmetricKey(size: .bits256)
        let backup = try Self.makeBackup([Self.record], key: key)
        let entries = try CoconutBatteryBackup.entries(
            from: backup, keyCandidates: [SymmetricKey(size: .bits256), key])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.deviceType == .mac)
        #expect(entry.deviceSerial == "MAC1")
        #expect(entry.cycleCount == 2)
        #expect(entry.designCapacity == 4629)
        #expect(entry.fullChargeCapacity == 4641)
        #expect(entry.osVersion == "26.0.1")
        #expect(entry.date.timeIntervalSince1970 == 1760824767.598602)
        #expect(entry.comment == "Imported from coconutBattery 4.0.0")
    }

    @Test func wrongKeyIsReported() throws {
        let backup = try Self.makeBackup([Self.record], key: SymmetricKey(size: .bits256))
        #expect(throws: CoconutBatteryBackup.ImportError.self) {
            try CoconutBatteryBackup.entries(from: backup, keyCandidates: [SymmetricKey(size: .bits256)])
        }
    }

    @Test func findsBase64KeysInBinary() {
        let key = Data((0..<32).map { UInt8($0) })
        var binary = Data([0, 1, 2]) + Data("not-a-key".utf8) + Data([0])
        binary += Data(key.base64EncodedString().utf8) + Data([0, 0])
        binary += Data("aGVsbG8=".utf8) + Data([0]) // decodes, but not 32 bytes
        let candidates = CoconutBatteryBackup.keyCandidates(in: binary)
        #expect(candidates.count == 1)
        #expect(candidates.first?.withUnsafeBytes { Data($0) } == key)
    }

    @Test func importSkipsDuplicates() throws {
        let store = try HistoryStore(url: nil)
        let entries = [CoconutBatteryBackup.entry(from: Self.record)!]
        try #expect(store.importEntries(entries) == 1)
        try #expect(store.importEntries(entries) == 0)
    }
}

@Suite struct CoconutBatterySanitizingTests {
    @Test func percentageAndMissingCapacitiesAreDropped() {
        var record = CoconutBatteryImportTests.record
        record["Battery.FCC"] = 100
        record["Battery.DC"] = -1
        let entry = CoconutBatteryBackup.entry(from: record)
        #expect(entry?.fullChargeCapacity == nil)
        #expect(entry?.designCapacity == nil)
        #expect(entry?.cycleCount == 2)
        #expect(entry?.healthFraction == nil)
    }
}

@Suite struct MenuBarFormatTests {
    static let values = MenuBarValues(
        chargeFraction: 0.764, cycleCount: 46, temperatureText: "24.6°C", healthFraction: 0.98,
        timeRemainingMinutes: 165, isCharging: false, systemWatts: 4.21, batteryWatts: -3.14, chargerWatts: 20)

    @Test func rendersEveryToken() {
        let format = MenuBarToken.allCases.map(\.rawValue).joined(separator: " ")
        #expect(MenuBarFormatter.render(format, values: Self.values)
            == "76% 46 24.6°C 98% 2:45 Battery 4.2 W −3.1 W 20 W")
    }

    @Test func missingValuesAndStates() {
        var values = MenuBarValues(isCharging: true, isExternalPowerConnected: true)
        #expect(MenuBarFormatter.render("%CHARGE% %STATUS%", values: values) == "– Charging")
        values.isFullyCharged = true
        #expect(MenuBarFormatter.render("%TIMEREM% %STATUS%", values: values) == "Full Full")
        #expect(MenuBarFormatter.render("Bat: %CHARGE%", values: Self.values) == "Bat: 76%")
        let calculating = MenuBarValues(isCalculatingTimeRemaining: true)
        #expect(MenuBarFormatter.render("%TIMEREM%", values: calculating) == "Calculating…")
    }

    @Test func tokensInOrderIgnoringOtherText() {
        #expect(MenuBarToken.tokens(in: "Bat: %HEALTH% %CHARGE% (%HEALTH%)") == [.health, .charge])
        #expect(MenuBarToken.tokens(in: "") == [])
        #expect(MenuBarToken.format([.charge, .timeRemaining]) == "%CHARGE% %TIMEREM%")
    }
}

@Suite struct BatteryAlertTests {
    static let settings = BatteryAlertSettings(lowChargePercent: 20, lowTimeMinutes: 30, fullyCharged: true)
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func onBattery(_ percent: Int, minutes: Int? = 90) -> BatteryReading {
        BatteryReading(chargePercent: percent, timeToEmptyMinutes: minutes,
                       isExternalPowerConnected: false, isFullyCharged: false)
    }

    @Test func lowChargeFiresOncePerDischarge() {
        var state = BatteryAlertState()
        var (alerts, next) = BatteryAlertRules.evaluate(Self.onBattery(25), settings: Self.settings, state: state, now: Self.t0)
        #expect(alerts.isEmpty)
        state = next
        (alerts, next) = BatteryAlertRules.evaluate(Self.onBattery(19), settings: Self.settings, state: state, now: Self.t0)
        #expect(alerts == [.lowCharge(percent: 19)])
        state = next
        // Still low an hour later: no repeat until power is connected.
        (alerts, next) = BatteryAlertRules.evaluate(Self.onBattery(12), settings: Self.settings, state: state,
                                                    now: Self.t0.addingTimeInterval(3600))
        #expect(alerts.isEmpty)
        state = next
        // Plug in, unplug: re-armed, and 15 minutes have passed.
        let plugged = BatteryReading(chargePercent: 13, timeToEmptyMinutes: nil, isExternalPowerConnected: true, isFullyCharged: false)
        state = BatteryAlertRules.evaluate(plugged, settings: Self.settings, state: state, now: Self.t0.addingTimeInterval(3700)).1
        (alerts, _) = BatteryAlertRules.evaluate(Self.onBattery(13), settings: Self.settings, state: state,
                                                 now: Self.t0.addingTimeInterval(3800))
        #expect(alerts == [.lowCharge(percent: 13)])
    }

    @Test func repeatNeedsFifteenMinutes() {
        var state = BatteryAlertState()
        state = BatteryAlertRules.evaluate(Self.onBattery(19), settings: Self.settings, state: state, now: Self.t0).1
        let plugged = BatteryReading(chargePercent: 19, timeToEmptyMinutes: nil, isExternalPowerConnected: true, isFullyCharged: false)
        state = BatteryAlertRules.evaluate(plugged, settings: Self.settings, state: state, now: Self.t0.addingTimeInterval(60)).1
        let (alerts, _) = BatteryAlertRules.evaluate(Self.onBattery(19), settings: Self.settings, state: state,
                                                     now: Self.t0.addingTimeInterval(120))
        #expect(alerts.isEmpty)
    }

    @Test func lowTime() {
        let (alerts, _) = BatteryAlertRules.evaluate(Self.onBattery(50, minutes: 25), settings: Self.settings,
                                                     state: BatteryAlertState(), now: Self.t0)
        #expect(alerts == [.lowTime(minutes: 25)])
    }

    @Test func fullyChargedFiresAfterChargingNotAtLaunch() {
        let full = BatteryReading(chargePercent: 100, timeToEmptyMinutes: nil, isExternalPowerConnected: true, isFullyCharged: true)
        let charging = BatteryReading(chargePercent: 98, timeToEmptyMinutes: nil, isExternalPowerConnected: true, isFullyCharged: false)
        // Launched while already full: quiet.
        var (alerts, state) = BatteryAlertRules.evaluate(full, settings: Self.settings, state: BatteryAlertState(), now: Self.t0)
        #expect(alerts.isEmpty)
        // Discharge a little, charge back to full: one alert.
        state = BatteryAlertRules.evaluate(charging, settings: Self.settings, state: state, now: Self.t0).1
        (alerts, state) = BatteryAlertRules.evaluate(full, settings: Self.settings, state: state, now: Self.t0)
        #expect(alerts == [.fullyCharged])
        (alerts, _) = BatteryAlertRules.evaluate(full, settings: Self.settings, state: state, now: Self.t0)
        #expect(alerts.isEmpty)
    }

    @Test func disabledAlertsStayQuiet() {
        let (alerts, _) = BatteryAlertRules.evaluate(Self.onBattery(5, minutes: 5), settings: BatteryAlertSettings(),
                                                     state: BatteryAlertState(), now: Self.t0)
        #expect(alerts.isEmpty)
    }
}

@Suite struct DurationFormatTests {
    @Test func readable() {
        #expect(DurationFormat.readable(836) == "13 h 56 min")
        #expect(DurationFormat.readable(120) == "2 h")
        #expect(DurationFormat.readable(45) == "45 min")
        #expect(DurationFormat.hoursMinutes(165) == "2:45")
    }
}

@Suite struct IOSDeviceTests {
    /// Shaped like the lockdown, diagnostics IORegistry and MobileGestalt replies.
    @Test func parsesDeviceAndBattery() {
        let info: [String: Any] = [
            "DeviceName": "Test iPhone", "ProductType": "iPhone16,1", "ProductVersion": "26.1",
            "SerialNumber": "ABC123", "ModelNumber": "MTUV3", "RegionInfo": "B/A",
        ]
        let battery: [String: Any] = ["IORegistry": [
            "AppleRawCurrentCapacity": 2100, "AppleRawMaxCapacity": 3000, "DesignCapacity": 3274,
            "CurrentCapacity": 70, "MaxCapacity": 100, "CycleCount": 412, "Temperature": 2950,
            "Voltage": 3900, "InstantAmperage": -300, "IsCharging": false, "ExternalConnected": false,
            "Serial": "F8Y000", "BatteryData": ["LifetimeData": ["TotalOperatingTime": 9000]],
        ] as [String: Any]]
        let device = IOSDeviceSnapshot(udid: "UDID", connection: .usb, info: info, battery: battery,
                                       gestalt: ["MobileGestalt": ["MarketingName": "iPhone 15 Pro"]])
        #expect(device.name == "Test iPhone")
        #expect(device.marketingName == "iPhone 15 Pro")
        #expect(device.deviceClass == "iPhone")
        #expect(device.modelNumber == "MTUV3B/A")
        #expect(device.battery?.cycleCount == 412)
        #expect(device.battery?.fullChargeCapacity == 3000)
        #expect(abs((device.battery?.healthFraction ?? 0) - 3000.0 / 3274) < 0.0001)
        #expect(device.battery?.temperatureCelsius == 29.5)
        #expect(device.battery?.manufacturer == "Sunwoda")
        #expect(device.battery?.lifetime?.totalOperatingHours == 9000)
    }

    @Test func fallsBackToModelTableAndIdentifier() {
        let known = IOSDeviceSnapshot(udid: "A", connection: .wifi, info: ["ProductType": "iPhone17,1"],
                                      battery: nil, gestalt: nil)
        #expect(known.marketingName == "iPhone 16 Pro")
        #expect(known.battery == nil)
        let unknown = IOSDeviceSnapshot(udid: "B", connection: .usb, info: ["ProductType": "iPad99,9"],
                                        battery: nil, gestalt: nil)
        #expect(unknown.marketingName == "iPad99,9")
        #expect(unknown.deviceClass == "iPad")
    }
}

@Suite struct IPhonePackTests {
    @Test func lifetimeTemperatureUnitsAndFirstUse() {
        // iPhone 18 Pro Max pack values: min/max in tenths, average in degrees.
        let pack: [String: Any] = [
            "Temperature": 3189, "DateOfFirstUse": 811_468_800,
            "LifetimeData": ["MinimumTemperature": 171, "MaximumTemperature": 543, "AverageTemperature": 27,
                             "TotalOperatingTime": 987],
        ]
        let registry: [String: Any] = ["CurrentCapacity": 93, "MaxCapacity": 100, "CycleCount": 22,
                                       "BatteryData": ["FullChargeCapacity": 5415, "DesignCapacity": 5335,
                                                       "RemainingCapacity": 4774]]
        let snapshot = MacBatterySnapshot(registry: registry, pack: pack, smc: nil, powerSource: nil)
        #expect(snapshot.lifetime?.minimumTemperatureCelsius == 17.1)
        #expect(snapshot.lifetime?.maximumTemperatureCelsius == 54.3)
        #expect(snapshot.lifetime?.averageTemperatureCelsius == 27)
        #expect(snapshot.temperatureCelsius == 31.89)
        #expect(snapshot.chargeFraction(style: .apple) == 0.93)
        let firstUse = snapshot.firstUseDate.map { ManufactureDateTests.utc.dateComponents([.year, .month, .day], from: $0) }
        #expect(firstUse == DateComponents(year: 2026, month: 9, day: 19))
        // "900618" isn't a valid week/month code, so no manufacture week is invented.
        #expect(snapshot.manufactureWeek == nil)
    }
}

@Suite struct DeviceChargeAlertTests {
    @Test func firesOnceWhileChargingAndRearms() {
        var armed = true
        var result = DeviceChargeAlertRule.evaluate(percent: 78, isCharging: true, threshold: 80, armed: armed)
        #expect(!result.notify); armed = result.armed
        result = DeviceChargeAlertRule.evaluate(percent: 80, isCharging: true, threshold: 80, armed: armed)
        #expect(result.notify); armed = result.armed
        result = DeviceChargeAlertRule.evaluate(percent: 85, isCharging: true, threshold: 80, armed: armed)
        #expect(!result.notify); armed = result.armed
        // Discharging back to 77% isn't enough to re-arm; 75% is.
        result = DeviceChargeAlertRule.evaluate(percent: 77, isCharging: false, threshold: 80, armed: armed)
        #expect(!result.armed); armed = result.armed
        result = DeviceChargeAlertRule.evaluate(percent: 75, isCharging: false, threshold: 80, armed: armed)
        #expect(result.armed); armed = result.armed
        result = DeviceChargeAlertRule.evaluate(percent: 81, isCharging: true, threshold: 80, armed: armed)
        #expect(result.notify)
    }

    @Test func notWhenNotCharging() {
        let result = DeviceChargeAlertRule.evaluate(percent: 90, isCharging: false, threshold: 80, armed: true)
        #expect(!result.notify && result.armed)
    }
}

@Suite struct AdvancedInfoTests {
    @Test func treeFromPropertyList() {
        let node = InfoNode.tree("Battery", [
            "CycleCount": 46, "IsCharging": NSNumber(value: true), "Raw": Data([0xde, 0xad]),
            "Nested": ["A": 1], "List": [1, 2],
        ] as [String: Any])
        #expect(node.value == "5 items")
        #expect(node.children?.map(\.title) == ["CycleCount", "IsCharging", "List", "Nested", "Raw"])
        let values = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.title, $0.value) })
        #expect(values["IsCharging"] == "Yes")
        #expect(values["Raw"] == "dead")
        #expect(values["Nested"] == "1 item")
        #expect(values["List"] == "2 items")
        // Ids include the path, so identical keys in different branches stay distinct.
        #expect(node.children?.first { $0.title == "Nested" }?.children?.first?.id == "Battery/Nested/A")
    }

    @Test func tabSeparatedCopy() {
        let node = InfoNode("Storage", "1 drive", children: [InfoNode("Life used", "0%", path: "Storage")])
        #expect(node.tabSeparated() == ["Storage\t1 drive", "  Life used\t0%"])
    }

    @Test func usbSpeeds() {
        #expect(AdvancedInfo.usbSpeed(2) == "USB 2.0 High Speed (480 Mb/s)")
        #expect(AdvancedInfo.usbSpeed(9).hasPrefix("Unknown"))
    }
}

@Suite struct MacSerialDateTests {
    @Test func classicSerials() {
        // Position 4 'F' = 2011 first half, position 5 '3' = week 3 → Monday 17 Jan 2011.
        #expect(BatteryOrigin.macManufactureDate(serial: "C02F3ABCDH2G", modelIdentifier: "MacBookPro8,1")
            == DateComponents(year: 2011, month: 1, day: 17))
        // 'G' = 2011 second half, week code '1' → week 27 → 4 Jul 2011.
        #expect(BatteryOrigin.macManufactureDate(serial: "C02G1ABCDH2G", modelIdentifier: "MacBookPro8,1")
            == DateComponents(year: 2011, month: 7, day: 4))
        // Same letters a decade later for 2020-era Intel models.
        #expect(BatteryOrigin.macManufactureDate(serial: "C02F3ABCDH2G", modelIdentifier: "MacBookAir9,1")
            == DateComponents(year: 2021, month: 1, day: 18))
    }

    @Test func randomSerialsHaveNoDate() {
        #expect(BatteryOrigin.macManufactureDate(serial: "HKHF74H9DD", modelIdentifier: "Mac16,12") == nil)
    }
}

@Suite struct ChargingPausedTests {
    static func snapshot(reason: Int, charging: Bool, connected: Bool = true, full: Bool = false) -> MacBatterySnapshot {
        MacBatterySnapshot(registry: [
            "ExternalConnected": connected, "IsCharging": charging, "FullyCharged": full,
            "ChargerData": ["NotChargingReason": reason],
        ], smc: nil, powerSource: nil)
    }

    /// Readings from an iPhone 18 Pro Max at 89%, toggling iOS's charge limit.
    @Test func matchesObservedReadings() {
        #expect(Self.snapshot(reason: 16_777_216, charging: false).isChargingPausedBySettings)
        #expect(!Self.snapshot(reason: 0, charging: true).isChargingPausedBySettings)
    }

    @Test func otherReasonsAndStatesAreNotPaused() {
        #expect(!Self.snapshot(reason: 128, charging: false, connected: false).isChargingPausedBySettings)
        #expect(!Self.snapshot(reason: 16_777_216, charging: false, full: true).isChargingPausedBySettings)
        #expect(!Self.snapshot(reason: 16_777_216, charging: false, connected: false).isChargingPausedBySettings)
        #expect(!Self.snapshot(reason: 2, charging: false).isChargingPausedBySettings)
    }
}

@Suite struct ChargerCheckTests {
    /// `AdapterDetails` of Apple's 30W USB-C Power Adapter on an M4 MacBook Air.
    nonisolated(unsafe) static let appleCharger: [String: Any] = [
        "Watts": 30, "Name": "30W USB-C Power Adapter", "Description": "pd charger",
        "Manufacturer": "Apple Inc.", "AdapterVoltage": 20000, "Current": 1490, "IsWireless": false,
        "UsbHvcHvcIndex": 3,
        "UsbHvcMenu": [
            ["Index": 0, "MaxCurrent": 2960, "MaxVoltage": 5000],
            ["Index": 1, "MaxCurrent": 2980, "MaxVoltage": 9000],
            ["Index": 2, "MaxCurrent": 1990, "MaxVoltage": 15000],
            ["Index": 3, "MaxCurrent": 1490, "MaxVoltage": 20000],
        ],
    ]

    static func battery(adapter: [String: Any], charging: Bool = true, currentCapacity: Int = 2000,
                        amperage: Int = 2000, powerIn: Int? = 28240) -> MacBatterySnapshot {
        var registry = SnapshotTests.appleSilicon
        registry["AdapterDetails"] = adapter
        registry["IsCharging"] = charging
        registry["InstantAmperage"] = amperage
        registry["BatteryData"] = ["DesignCapacity": 4629, "FullChargeCapacity": 4556,
                                   "RemainingCapacity": currentCapacity]
        if let powerIn { registry["PowerTelemetryData"] = ["SystemPowerIn": powerIn] }
        return MacBatterySnapshot(registry: registry, smc: nil, powerSource: nil)
    }

    @Test func readsUSBPowerDeliveryProfiles() throws {
        let battery = Self.battery(adapter: Self.appleCharger)
        let adapter = try #require(battery.adapter)
        #expect(adapter.name == "30W USB-C Power Adapter")
        #expect(adapter.manufacturer == "Apple Inc.")
        #expect(adapter.profiles.count == 4)
        #expect(adapter.activeProfile == PowerProfile(voltageMillivolts: 20000, maxCurrentMilliamps: 1490))
        #expect(abs((adapter.maximumOfferedWatts ?? 0) - 29.85) < 0.01)
        #expect(ChargerCheck.agreedText(adapter) == "20 V × 1.49 A")
        #expect(ChargerCheck.profilesText(adapter) == "5 V 2.96 A · 9 V 2.98 A · 15 V 1.99 A · 20 V 1.49 A")
        #expect(battery.chargerInputMilliwatts == 28240)
    }

    @Test func fullyLoadedChargerLimitsSpeedBelowEightyPercent() {
        let low = Self.battery(adapter: Self.appleCharger, currentCapacity: 2000)
        let advice = ChargerCheck.advice(battery: low, inputWatts: 28.2)
        #expect(advice.count == 1)
        #expect(advice.first?.level == .info)
        #expect(advice.first?.message.contains("28 W of 30 W") == true)

        // Charging tapers above 80%, so the charger isn't what limits it there.
        let high = Self.battery(adapter: Self.appleCharger, currentCapacity: 4000)
        #expect(ChargerCheck.advice(battery: high, inputWatts: 28.2).isEmpty)
        // Plenty of headroom.
        #expect(ChargerCheck.advice(battery: low, inputWatts: 15).isEmpty)
    }

    @Test func warnsWhenDrainingWhilePluggedIn() {
        let battery = Self.battery(adapter: Self.appleCharger, charging: false, amperage: -900)
        let advice = ChargerCheck.advice(battery: battery, inputWatts: 29, systemWatts: 40)
        #expect(advice.first?.level == .caution)
        #expect(advice.first?.message.contains("29 W in, 40 W used") == true)
        // A limiter that switches the charger off on purpose isn't the charger's fault.
        #expect(ChargerCheck.advice(battery: battery, inputWatts: 0).isEmpty)
    }

    @Test func flagsBasicUSBSupplies() {
        let usb: [String: Any] = ["Watts": 5, "AdapterVoltage": 5000, "Current": 1000]
        let advice = ChargerCheck.advice(battery: Self.battery(adapter: usb), inputWatts: 4.8)
        #expect(advice.count == 1)
        #expect(advice.first?.message.contains("basic 5 V USB supply (5.0 W)") == true)
    }

    @Test func nothingOnBattery() {
        var battery = Self.battery(adapter: Self.appleCharger)
        battery.isExternalPowerConnected = false
        #expect(ChargerCheck.advice(battery: battery, inputWatts: 30).isEmpty)
    }
}

@Suite struct HealthForecastTests {
    static let start = ManufactureDateTests.utc.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 12))!

    /// One reading a day losing `perYear` of design capacity, plus a ±1% wobble.
    static func entries(days: Int, from health: Double = 1.0, perYear: Double, every step: Int = 1,
                        batterySerial: String = "F8Y") -> [HistoryEntry] {
        stride(from: 0, to: days, by: step).map { day in
            let wobble = [0.0, 0.01, -0.01][day % 3]
            let fraction = health + perYear * Double(day) / 365.25 + wobble
            return HistoryEntry(date: start.addingTimeInterval(Double(day) * 86_400), deviceType: .mac,
                                deviceSerial: "MAC1", deviceName: "MacBook Air", deviceModel: "Mac16,12",
                                batterySerial: batterySerial, cycleCount: day / 2, designCapacity: 5000,
                                fullChargeCapacity: Int(fraction * 5000))
        }
    }

    static func forecast(_ entries: [HistoryEntry]) throws -> HealthForecast {
        guard case let .forecast(forecast) = HealthForecast.trend(entries: entries, calendar: ManufactureDateTests.utc)
        else { throw CancellationError() }
        return forecast
    }

    @Test func fitsSteadyLossDespiteNoise() throws {
        let forecast = try Self.forecast(Self.entries(days: 200, perYear: -0.05))
        #expect(abs(forecast.changePerYear - -0.05) < 0.005)
        #expect(forecast.readingDays == 200)
        #expect(abs((forecast.cyclesPerMonth ?? 0) - 15.2) < 0.5)
        // 1.0 − 0.05 × 199/365 ≈ 0.973 now; 0.173 to lose at 5%/year ≈ 3.5 years.
        guard case let .reaches(date) = forecast.outlook else {
            Issue.record("expected a date")
            return
        }
        let years = date.timeIntervalSince(forecast.latestDate) / (365.25 * 86_400)
        #expect(abs(years - 3.46) < 0.3)
        #expect(HealthTrend.forecast(forecast).summary.hasPrefix("Losing 5.0% a year; 80% around"))
    }

    @Test func ignoresARecalibrationJump() throws {
        var entries = Self.entries(days: 120, perYear: -0.04)
        for index in 60..<64 { entries[index].fullChargeCapacity! -= 400 }
        #expect(abs(try Self.forecast(entries).changePerYear - -0.04) < 0.01)
    }

    @Test func needsTwoMonthsOfHistory() {
        #expect(HealthForecast.trend(entries: Self.entries(days: 30, perYear: -0.05),
                                     calendar: ManufactureDateTests.utc)
            == .collecting(days: 29, readingDays: 30))
        #expect(HealthTrend.collecting(days: 29, readingDays: 30).summary == "Collecting history (29 of 60 days)")
        // Long enough but too sparse.
        #expect(HealthForecast.trend(entries: Self.entries(days: 90, perYear: -0.05, every: 30),
                                     calendar: ManufactureDateTests.utc)
            == .collecting(days: 60, readingDays: 3))
        #expect(HealthForecast.trend(entries: [], calendar: ManufactureDateTests.utc) == nil)
    }

    @Test func stableAndBelowThreshold() throws {
        #expect(try Self.forecast(Self.entries(days: 100, perYear: 0)).outlook == .stable)
        let old = try Self.forecast(Self.entries(days: 100, from: 0.79, perYear: -0.03))
        #expect(old.outlook == .belowThreshold)
        #expect(HealthTrend.forecast(old).summary == "Losing 3.0% a year; already below 80%")
        let slow = try Self.forecast(Self.entries(days: 100, from: 0.95, perYear: -0.01))
        #expect(slow.outlook == .beyondHorizon)
    }

    @Test func onlyUsesTheCurrentBattery() throws {
        // A worn battery was replaced: the old readings must not drag the new trend down.
        let old = Self.entries(days: 100, from: 0.75, perYear: -0.1, batterySerial: "OLD")
        let new = Self.entries(days: 100, from: 1.0, perYear: 0).map { entry in
            var entry = entry
            entry.date += 100 * 86_400
            entry.batterySerial = "NEW"
            return entry
        }
        let forecast = try Self.forecast(old + new)
        #expect(forecast.outlook == .stable)
        #expect(forecast.readingDays == 100)
    }
}

@Suite struct CellBalanceTests {
    @Test func cellsFromSMCOnAppleSilicon() {
        // BC1V–BC3V read from an M4 MacBook Air; they sum to the pack voltage.
        // Integers are little-endian on Apple silicon and big-endian on Intel.
        func ui16(_ bytes: [UInt8]) -> SMCValue {
            SMCValue(type: "ui16", bytes: SMCValue.hostUsesLittleEndianIntegers ? bytes : bytes.reversed())
        }
        let smc = FakeSMC(values: [
            "BC1V": ui16([0x45, 0x11]), "BC2V": ui16([0x4F, 0x11]), "BC3V": ui16([0x51, 0x11]),
        ])
        let snapshot = MacBatterySnapshot(registry: SnapshotTests.appleSilicon, smc: smc, powerSource: nil)
        #expect(snapshot.cellVoltagesMillivolts == [4421, 4431, 4433])
        #expect(CellBalance.text(snapshot.cellVoltagesMillivolts) == "4.421 · 4.431 · 4.433 V (12 mV apart)")
        #expect(CellBalance.advice(snapshot.cellVoltagesMillivolts) == nil)
    }

    @Test func cellsFromIntelRegistry() {
        var registry = SnapshotTests.appleSilicon
        registry["BatteryData"] = ["CellVoltage": [3801, 3920, 3795, 0]]
        let snapshot = MacBatterySnapshot(registry: registry, smc: nil, powerSource: nil)
        #expect(snapshot.cellVoltagesMillivolts == [3801, 3920, 3795, 0])
    }

    @Test func warnsAboutALargeGap() {
        #expect(CellBalance.advice([3801, 3920, 3795])?.message.hasPrefix("The cells differ by 125 mV") == true)
        #expect(CellBalance.spread([3800]) == nil)
    }
}

@Suite struct SleepDrainTests {
    static let night = ManufactureDateTests.utc.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23))!

    static func battery(_ capacity: Int, plugged: Bool = false) -> MacBatterySnapshot {
        var registry = SnapshotTests.appleSilicon
        registry["ExternalConnected"] = plugged
        registry["BatteryData"] = ["DesignCapacity": 4629, "FullChargeCapacity": 4500, "RemainingCapacity": capacity]
        return MacBatterySnapshot(registry: registry, smc: nil, powerSource: nil)
    }

    @Test func measuresOvernightLoss() throws {
        let session = try #require(SleepSession(before: Self.battery(4000), after: Self.battery(3865),
                                                sleptAt: Self.night, wokeAt: Self.night + 8 * 3600))
        #expect(abs(session.lossFraction - 0.03) < 0.0001)
        #expect(abs(session.lossPerHour - 0.00375) < 0.0001)
        #expect(SleepDrain.summary(session) == "Lost 3% in 8 h (0.4% an hour)")
        #expect(SleepDrain.advice([session]) == nil)
    }

    @Test func skipsWhatCantBeMeasured() {
        let wake = Self.night + 8 * 3600
        // Plugged in at either end, charged in between, or too short.
        #expect(SleepSession(before: Self.battery(4000, plugged: true), after: Self.battery(3900),
                             sleptAt: Self.night, wokeAt: wake) == nil)
        #expect(SleepSession(before: Self.battery(4000), after: Self.battery(3900, plugged: true),
                             sleptAt: Self.night, wokeAt: wake) == nil)
        #expect(SleepSession(before: Self.battery(3000), after: Self.battery(3900),
                             sleptAt: Self.night, wokeAt: wake) == nil)
        #expect(SleepSession(before: Self.battery(4000), after: Self.battery(3990),
                             sleptAt: Self.night, wokeAt: Self.night + 600) == nil)
    }

    @Test func treatsASmallGaugeRiseAsNoLoss() throws {
        // The gauge revised the charge up by 20 mAh (0.4%) after heavy use: no loss.
        let rested = try #require(SleepSession(before: Self.battery(4000), after: Self.battery(4020),
                                               sleptAt: Self.night, wokeAt: Self.night + 1800))
        #expect(rested.lossFraction == 0)
        #expect(SleepDrain.summary(rested) == "Lost less than 1% in 30 min (0.0% an hour)")
        // Over 1% (45 mAh) means it charged.
        #expect(SleepSession(before: Self.battery(4000), after: Self.battery(4050),
                             sleptAt: Self.night, wokeAt: Self.night + 1800) == nil)
    }

    @Test func flagsHeavyDrainOnLongSleeps() {
        let heavy = SleepSession(start: Self.night, end: Self.night + 5 * 3600,
                                 startCapacity: 4000, endCapacity: 3550, fullChargeCapacity: 4500)
        #expect(SleepDrain.advice([heavy])?.message.hasPrefix("The last sleep used 2.0% an hour") == true)
        // The same rate over a short nap isn't reliable enough to warn about.
        var nap = heavy
        nap.end = Self.night + 3600
        nap.endCapacity = 3910
        #expect(SleepDrain.advice([nap]) == nil)
        #expect(abs((SleepDrain.averageLossPerHour([heavy, nap]) ?? 0) - 0.12 / 6) < 0.0001)
    }

    @Test func storeKeepsEverySessionNewestFirstWithBriefWakes() throws {
        let store = try HistoryStore(url: nil)
        for index in 0..<150 {
            let end = Self.night + Double(index) * 86_400
            try store.insert(SleepSession(start: end - 8 * 3600, end: end, startCapacity: 4000,
                                          endCapacity: 3900, fullChargeCapacity: 4500,
                                          briefWakes: index == 149 ? 12 : nil))
        }
        var sessions = try store.sleepSessions()
        #expect(sessions.count == 150)
        #expect(sessions.first?.end == Self.night + 149 * 86_400)
        #expect(sessions.first?.briefWakes == 12)
        #expect(sessions[1].briefWakes == nil)
        try store.setBriefWakes(3, forSleepSession: sessions[1].id)
        sessions = try store.sleepSessions()
        #expect(sessions[1].briefWakes == 3)
    }

    @Test func countsBriefWakesOnlyWhereReadingsReach() {
        let session = SleepSession(start: Self.night, end: Self.night + 8 * 3600, startCapacity: 4000,
                                   endCapacity: 3900, fullChargeCapacity: 4500)
        func minute(_ offset: TimeInterval) -> PowerMinute {
            PowerMinute(start: Self.night + offset, averageWatts: 1, peakWatts: 2, chargePercent: 80, onAdapter: false)
        }
        // Readings before the sleep, then two separate wakes (one two minutes long).
        let minutes = [minute(-600), minute(3600), minute(3660), minute(7200)]
        #expect(SleepDrain.briefWakes(during: session, minutes: minutes) == 2)
        // Readings that start after the sleep began can't say how often it woke.
        #expect(SleepDrain.briefWakes(during: session, minutes: Array(minutes.dropFirst())) == nil)
        #expect(SleepDrain.briefWakes(during: session, minutes: []) == nil)
    }

    @Test func summarisesSleepsInAPeriod() {
        let calm = SleepSession(start: Self.night, end: Self.night + 8 * 3600, startCapacity: 4000,
                                endCapacity: 3910, fullChargeCapacity: 4500, briefWakes: 16)
        let heavy = SleepSession(start: Self.night + 86_400, end: Self.night + 86_400 + 4 * 3600,
                                 startCapacity: 4000, endCapacity: 3640, fullChargeCapacity: 4500)
        let stats = SleepStats([calm, heavy])
        #expect(stats.count == 2)
        #expect(stats.hours == 12)
        #expect(abs(stats.lossFraction - 0.10) < 0.0001)
        #expect(abs((stats.lossPerHour ?? 0) - 0.10 / 12) < 0.0001)
        #expect(abs((stats.lossPerSleep ?? 0) - 0.05) < 0.0001)
        // Only the sleep with counted wakes: 16 over 8 hours.
        #expect(stats.briefWakesPerHour == 2)
        #expect(stats.highLossCount == 1)
        #expect(SleepStats([]).lossPerHour == nil)
    }

    @Test func picksSleepsByPeriod() {
        let calendar = ManufactureDateTests.utc
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 21))!
        func ending(daysAgo: Int, hour: Int = 7) -> SleepSession {
            let end = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))! + Double(hour) * 3600
            return SleepSession(start: end - 8 * 3600, end: end, startCapacity: 4000, endCapacity: 3900,
                                fullChargeCapacity: 4500)
        }
        let sessions = [ending(daysAgo: 0), ending(daysAgo: 6), ending(daysAgo: 7), ending(daysAgo: 40)]
        #expect(SleepPeriod.week.sessions(sessions, from: now, to: now, now: now, calendar: calendar).count == 2)
        #expect(SleepPeriod.month.sessions(sessions, from: now, to: now, now: now, calendar: calendar).count == 3)
        #expect(SleepPeriod.all.sessions(sessions, from: now, to: now, now: now, calendar: calendar).count == 4)
        // Custom covers whole days at both ends, in either order.
        let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now)!
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        #expect(SleepPeriod.custom.sessions(sessions, from: sixDaysAgo, to: sevenDaysAgo, now: now,
                                            calendar: calendar).count == 2)
    }
}

@Suite struct PowerTimelineTests {
    static let start = ManufactureDateTests.utc.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!

    static func minute(_ offset: Int, watts: Double = 6, charge: Int? = 80) -> PowerMinute {
        PowerMinute(start: start + Double(offset) * 60, averageWatts: watts, peakWatts: watts + 2,
                    chargePercent: charge, onAdapter: false)
    }

    @Test func offersLongerPeriodsOnceThereAreRecordsForThem() {
        let now = Self.start
        let day = PowerPeriod.day.duration
        #expect(PowerPeriod.available(recordedSince: nil, now: now) == [.live, .hour, .day])
        #expect(PowerPeriod.available(recordedSince: now - day, now: now) == [.live, .hour, .day])
        #expect(PowerPeriod.available(recordedSince: now - day - 60, now: now) == [.live, .hour, .day, .week])
        #expect(PowerPeriod.available(recordedSince: now - 7 * day, now: now) == [.live, .hour, .day, .week])
        #expect(PowerPeriod.available(recordedSince: now - 7 * day - 60, now: now) == PowerPeriod.allCases)
    }

    @Test func aggregatesReadingsIntoMinutes() throws {
        var aggregator = PowerMinuteAggregator()
        #expect(aggregator.add(watts: 4, at: Self.start + 5, chargePercent: 80, onAdapter: false) == nil)
        #expect(aggregator.add(watts: 8, at: Self.start + 50, chargePercent: 79, onAdapter: false) == nil)
        let next = aggregator.add(watts: 5, at: Self.start + 65, chargePercent: 79, onAdapter: false)
        let finished = try #require(next)
        #expect(finished == PowerMinute(start: Self.start, averageWatts: 6, peakWatts: 8,
                                        chargePercent: 79, onAdapter: false))
        // Flushing before sleep keeps the partial minute.
        #expect(aggregator.flush()?.start == Self.start + 60)
        #expect(aggregator.flush() == nil)
    }

    @Test func bucketsAndBreaksAtGaps() {
        // An hour, a two-hour gap (asleep), then another hour.
        let minutes = (0..<60).map { Self.minute($0) } + (180..<240).map { Self.minute($0, watts: 12, charge: 60) }
        let now = Self.start + 240 * 60
        let day = now.addingTimeInterval(-86_400)...now
        let points = PowerTimeline.points(minutes, in: day)
        #expect(points.count == 24)
        #expect(points.first?.segment == 0)
        #expect(points.last?.segment == 1)
        #expect(points.last?.averageWatts == 12)
        #expect(points.last?.peakWatts == 14)
        #expect(points.last?.chargePercent == 60)
        // Readings outside the domain are left out.
        #expect(PowerTimeline.points(minutes, in: now.addingTimeInterval(-3600)...now).count == 60)
    }

    @Test func joinsTheChargeLineAcrossSleep() {
        // An hour at 80%, asleep for two hours with a brief wake, then an hour at 60%.
        let minutes = (0..<60).map { Self.minute($0) } + [Self.minute(120, charge: 70)]
            + (180..<240).map { Self.minute($0, charge: 60) }
        let sleep = DateInterval(start: Self.start + 59.5 * 60, end: Self.start + 180.5 * 60)
        let now = Self.start + 240 * 60
        let day = now.addingTimeInterval(-86_400)...now
        // Without the sleep, the line breaks at each gap.
        #expect(Set(PowerTimeline.chargeLine(minutes, in: day, sleeps: []).map(\.segment)) == [0, 1, 2])
        let joined = PowerTimeline.chargeLine(minutes, in: day, sleeps: [sleep])
        #expect(joined.allSatisfy { $0.segment == 0 })
        #expect(joined.first?.percent == 80)

        // Starting during the sleep, the line starts at the edge: halfway between the reading
        // just before sleep (59:30) and the brief wake (2:00:30), so 75%.
        let edge = Self.start + 90 * 60
        let trimmed = PowerTimeline.chargeLine(minutes, in: edge...(edge + 3600), sleeps: [sleep])
        #expect(trimmed.first?.date == edge)
        #expect(trimmed.first?.percent == 75)
        #expect(trimmed.allSatisfy { $0.segment == 0 })
        // Starting while the app wasn't running, it doesn't.
        #expect(PowerTimeline.chargeLine(minutes, in: edge...(edge + 3600), sleeps: []).first?.percent == 70)
    }

    @Test func averagesBarsOverSleepAndCarriesChargeThroughIt() {
        // As above: awake at 80%, asleep with a brief wake at 70%, then awake at 60%.
        let minutes = (0..<60).map { Self.minute($0) } + [Self.minute(120, charge: 70)]
            + (180..<240).map { Self.minute($0, charge: 60) }
        let sleep = DateInterval(start: Self.start + 59.5 * 60, end: Self.start + 180.5 * 60)
        let domain = Self.start...(Self.start + 240 * 60)
        #expect(PowerTimeline.barWidth(span: 240 * 60) == 300)
        let bars = PowerTimeline.bars(minutes, in: domain, sleeps: [sleep], calendar: ManufactureDateTests.utc)
        #expect(bars.count == 48)
        #expect(bars.first?.watts == 6)
        // The brief wake's minute is spread over its five-minute slot, which it lies
        // inside: 6 W for one minute of five, not of six.
        let wake = bars.first { $0.start == Self.start + 120 * 60 }
        #expect(abs((wake?.watts ?? 0) - 1.2) < 1e-9)
        // Asleep without readings: no power, but the charge carries on.
        let asleep = bars.first { $0.start == Self.start + 90 * 60 }
        #expect(asleep?.watts == nil)
        #expect(asleep?.chargePercent.map { $0 > 70 && $0 < 80 } == true)
    }

    @Test func trimsTheDomainToWhereReadingsStart() {
        let now = Self.start + 3 * 3600
        let minutes = (60..<180).map { Self.minute($0) }
        #expect(PowerTimeline.domain(period: .day, minutes: minutes, sleeps: [], now: now)
            == (Self.start + 3600)...now)
        // A sleep before the first reading counts too.
        let sleep = DateInterval(start: Self.start + 1800, end: Self.start + 3600)
        #expect(PowerTimeline.domain(period: .day, minutes: minutes, sleeps: [sleep], now: now)
            == (Self.start + 1800)...now)
        // Readings older than the period don't widen it.
        #expect(PowerTimeline.domain(period: .hour, minutes: [Self.minute(0)] + minutes, sleeps: [], now: now)
            == (now - 3600)...now)
        // Nothing saved: the whole period. Just started: at least ten minutes.
        #expect(PowerTimeline.domain(period: .day, minutes: [], sleeps: [], now: now) == (now - 86_400)...now)
        #expect(PowerTimeline.domain(period: .day, minutes: [Self.minute(179)], sleeps: [], now: now)
            == (now - 600)...now)
        #expect(PowerTimeline.bucket(span: 3600) == 60)
        #expect(PowerTimeline.bucket(span: 86_400) == 300)
        #expect(PowerTimeline.bucket(span: 30 * 86_400) == 7200)
    }

    @Test func clipsSleepsToThePeriod() {
        let now = Self.start + 3600
        let sleeps = [DateInterval(start: Self.start - 8 * 3600, end: Self.start + 600),
                      DateInterval(start: Self.start - 30 * 3600, end: Self.start - 26 * 3600)]
        let clipped = PowerTimeline.sleeps(sleeps, in: (now - 3600)...now)
        #expect(clipped == [DateInterval(start: Self.start, end: Self.start + 600)])
    }

    @Test func findsBriefWakesDuringSleep() {
        // Asleep from 9:00:20 to 10:00:20. The minutes at 9:00 and 10:00 hold readings
        // from before sleep and after waking, so only 9:20–9:21 and 9:45 count.
        let sleep = DateInterval(start: Self.start + 20, end: Self.start + 3620)
        let minutes = [0, 20, 21, 45, 60].map { Self.minute($0, watts: Double($0) / 10) }
        let wakes = PowerTimeline.briefWakes(minutes, sleeps: [sleep])
        #expect(wakes == [BriefWake(start: Self.start + 1200, end: Self.start + 1320, peakWatts: 4.1),
                          BriefWake(start: Self.start + 2700, end: Self.start + 2760, peakWatts: 6.5)])
        #expect(wakes.first?.middle == Self.start + 1260)
        #expect(PowerTimeline.briefWakes(minutes, sleeps: []).isEmpty)
        // Wakes within 25 minutes of each other share a mark.
        #expect(PowerTimeline.group(wakes, within: 25 * 60).map(\.count) == [2])
        #expect(PowerTimeline.group(wakes, within: 20 * 60).map(\.count) == [1, 1])
    }

    @Test func storeRoundTripsAndPrunes() throws {
        let store = try HistoryStore(url: nil)
        try store.insert(Self.minute(0))
        try store.insert(Self.minute(1, charge: nil))
        try store.insertSleepPeriod(DateInterval(start: Self.start + 120, end: Self.start + 7200))
        #expect(try store.powerMinutes(since: Self.start).count == 2)
        #expect(try store.powerMinutes(since: Self.start).last?.chargePercent == nil)
        #expect(try store.sleepPeriods(since: Self.start).count == 1)
        // A reading 31 days later drops the old ones.
        try store.insert(Self.minute(31 * 24 * 60))
        #expect(try store.powerMinutes(since: .distantPast).count == 1)
        #expect(try store.sleepPeriods(since: .distantPast).isEmpty)
    }

    @Test func batteryFlowLabels() {
        var battery = ChargerCheckTests.battery(adapter: ChargerCheckTests.appleCharger, amperage: 0)
        #expect(BatteryFlow.describe(battery) == ("Battery", "Not charging"))
        battery.isExternalPowerConnected = false
        #expect(BatteryFlow.describe(battery) == ("Battery", "Idle"))
        battery.amperageMilliamps = 1000
        #expect(BatteryFlow.describe(battery).title == "Charging with")
        battery.amperageMilliamps = -500
        #expect(BatteryFlow.describe(battery).title == "Discharging with")
    }
}

@Suite struct PowerAxisTests {
    @Test func ticksAtRoundTimesAwayFromEdges() {
        let utc = ManufactureDateTests.utc
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 11, minute: 50))!
        let day = PowerTimeline.ticks(domain: now.addingTimeInterval(-86_400)...now, calendar: utc)
        let hours = day.map { utc.component(.hour, from: $0) }
        // 12:00 yesterday is within 4% of the left edge and today's 12:00 is past the end.
        #expect(hours == [15, 18, 21, 0, 3, 6, 9])
        let week = PowerTimeline.ticks(domain: now.addingTimeInterval(-7 * 86_400)...now, calendar: utc)
        #expect(week.count == 7)
        #expect(week.allSatisfy { utc.component(.hour, from: $0) == 0 })
        // A trimmed span of 100 minutes gets ticks every 15 minutes.
        let short = PowerTimeline.ticks(domain: now.addingTimeInterval(-6000)...now, calendar: utc)
        #expect(short.map { utc.component(.minute, from: $0) } == [15, 30, 45, 0, 15, 30, 45])
        let spans: [TimeInterval] = [120, 3600, 30 * 86_400]
        let steps: [TimeInterval] = [30, 600, 5 * 86_400]
        #expect(spans.map { PowerTimeline.tickStep(span: $0) } == steps)
    }
}

@Suite struct CPUUsageTests {
    @Test func busyShareOfTicksBetweenReadings() {
        let earlier = CPUTicks(user: 1000, system: 500, idle: 8000, nice: 0)
        let later = CPUTicks(user: 1300, system: 600, idle: 8600, nice: 0)
        #expect(later.usage(since: earlier) == 0.4)
        #expect(later.usage(since: later) == nil)
    }

    @Test func survivesCounterWrap() {
        let earlier = CPUTicks(user: UInt64(UInt32.max) - 99, system: 0, idle: 0, nice: 0)
        let later = CPUTicks(user: 100, system: 0, idle: 200, nice: 0)
        #expect(later.usage(since: earlier) == 0.5)
    }

    @Test func readsThisMac() throws {
        let ticks = try #require(CPUTicks.read())
        #expect(ticks.user + ticks.system + ticks.idle > 0)
    }
}

@Suite struct SignificantEnergyTests {
    @Test func usesTheResponsibleAppAndSortsByImpact() {
        let report: [String: Any] = [
            "bundle_identifiers": ["com.google.Chrome.helper", "com.t3tools.t3code", "com.google.Chrome"],
            "responsible_bundle_identifiers": ["com.google.Chrome", "", ""],
            "display_names": ["", "T3 Code", ""],
            "energy_impacts": ["70000.5", NSNumber(value: 80000), "20000"],
            "report_duration": 120,
        ]
        let apps = SignificantEnergy.apps(from: report)
        #expect(apps.map(\.bundleIdentifier) == ["com.google.Chrome", "com.t3tools.t3code"])
        #expect(apps[0].energyImpact == 90000.5)
        #expect(apps[0].displayName == nil)
        #expect(apps[1].displayName == "T3 Code")
    }

    @Test func emptyReport() {
        #expect(SignificantEnergy.apps(from: ["bundle_identifiers": [String]()]).isEmpty)
    }

    @Test func readsThisMac() {
        #expect(SignificantEnergy.read() != nil)
    }
}

@Suite struct WakeLogTests {
    static let log = """
    PM ASL data store: /var/log/powermanagement
    Time stamp                Domain              \tMessage
    2026-10-24 01:23:10 +0100 Sleep               \tEntering Sleep state due to 'Clamshell Sleep' Using Batt (Charge:80%) 30 secs
    2026-10-24 01:23:12 +0100 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=7200 wakeAt=2026-10-24 03:23:12 info="upkeep wake"] [*process=dasd request=SleepService deltaSecs=999 wakeAt=2026-10-24 01:39:51 info="com.apple.dasd:501:com.apple.intelligenceflow.toolbox.update.fastpass"]
    2026-10-24 01:39:51 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:80%) 7 secs    
    2026-10-24 01:39:52 +0100 Assertions          \tPID 624(cloudd) Created SystemIsActive "com.apple.cloudd.sync" 00:00:00  id:0x0x1 [System: DeclUser]
    2026-10-24 01:39:53 +0100 Assertions          \tPID 545(powerd) Created InternalPreventSleep "PM configd - Wait for Device enumeration" 00:00:00  id:0x0x2 [System: DeclUser]
    2026-10-24 01:39:54 +0100 Assertions          \tPID 624(cloudd) Created SystemIsActive "com.apple.cloudd.sync" 00:00:00  id:0x0x3 [System: DeclUser]
    2026-10-24 01:39:55 +0100 Assertions          \tPID 1000(sharingd) Released PreventUserIdleSystemSleep "Handoff" 00:08:23  id:0x0x4 [System: DeclUser]
    2026-10-24 01:45:00 +0100 Assertions          \tPID 77(backupd) Created PreventSystemSleep "Backup" 00:00:00  id:0x0x5 [System: DeclUser]
    2026-10-24 01:40:00 +0100 Wake Requests       \t[*process=mDNSResponder request=Maintenance deltaSecs=7200 wakeAt=2026-10-24 03:40:00 info="upkeep wake"]
    2026-10-24 03:39:59 +0100 Assertions          \tPID 700(mDNSResponder) Created MaintenanceWake "mDNSResponder:maintenance" 00:00:00  id:0x0x6 [System: DeclUser]
    2026-10-24 03:40:00 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance Using BATT (Charge:79%) 5 secs
    2026-10-24 04:02:13 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty/ Using BATT (Charge:79%) 9 secs
    2026-10-24 05:10:00 +0100 Wake Requests       \t[*process=powerd request=UserWake deltaSecs=60 wakeAt=2026-10-24 05:11:00 info="com.apple.alarm.user-invisible-com.apple.acmd.alarm,532"]
    2026-10-24 05:11:00 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to rtc/UserWake Using BATT (Charge:79%) 3 secs
    2026-10-24 06:00:00 +0100 Wake                \tDarkWake to FullWake from Deep Idle [CDNVAP] : due to Notification Using BATT (Charge:79%) 5 secs
    2026-10-24 09:35:00 +0100 Wake                \tWake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty Using BATT (Charge:78%)
    """

    @Test func readsBriefWakesWithReasons() throws {
        let (wakes, since) = WakeLog.parse(Self.log)
        #expect(since == ISO8601DateFormatter().date(from: "2026-10-24T00:23:10Z"))
        // Full wakes ("Wake" domain) aren't brief wakes.
        #expect(wakes.map(\.reason) == [.scheduledTask, .networkUpkeep, .wireless, .scheduledTask])
        #expect(wakes[0].detail == "com.apple.intelligenceflow.toolbox.update.fastpass")
        #expect(wakes[0].date == ISO8601DateFormatter().date(from: "2026-10-24T00:39:51Z"))
        #expect(wakes[1].detail == "upkeep wake")
        #expect(wakes[2].detail == nil)
        #expect(wakes[3].detail == "com.apple.acmd.alarm")
        #expect(wakes.map(\.seconds) == [7, 5, 9, 3])
        // Assertions created during the wake, once each; not ones released, or made after it.
        #expect(wakes[0].holders == ["cloudd", "powerd"])
        // Made as the wake began, and logged just before it.
        #expect(wakes[1].holders == ["mDNSResponder"])
        #expect(wakes[2].holders.isEmpty)
    }

    @Test func readsAppsAndPushesFromTheSystemLog() throws {
        let log = #"""
        {"timestamp":"2026-10-24 04:02:14.120000+0100","eventMessage":"<private>: Received message for enabled topic '<private>' onInterface: <private>"}
        {"timestamp":"2026-10-24 01:39:55.384585+0100","eventMessage":"NDSession <C4790A93> Client com.apple.cloudd is acting on behalf of com.apple.Photos"}
        {"timestamp":"2026-10-24 01:39:56.000000+0100","eventMessage":"NDSession <C4790A94> Client com.dropbox.helper is acting on behalf of cloud"}
        {"timestamp":"2026-10-24 02:30:00.000000+0100","eventMessage":"NDSession <C4790A95> Client com.apple.cloudd is acting on behalf of com.apple.Notes"}
        {"count":4,"finished":1}
        """#
        let events = SystemLog.parse(log)
        #expect(events.count == 4)
        let (wakes, _) = WakeLog.parse(Self.log)
        let annotated = SystemLog.annotate(wakes, with: events)
        #expect(annotated[0].apps == ["com.apple.Photos", "com.dropbox.helper"])
        // Notes worked between wakes, so it's no wake's.
        #expect(annotated.allSatisfy { !$0.apps.contains("com.apple.Notes") })
        // The Wi-Fi wake with a push arriving.
        #expect(annotated.map(\.reason) == [.scheduledTask, .networkUpkeep, .pushNotification, .scheduledTask])
        #expect(SystemLog.app(in: "Client com.apple.cloudd is acting on behalf of cloud") == nil)
    }

    @Test func breakdownAddsUpTimeAwakeAndHolders() {
        let date = Date(timeIntervalSince1970: 0)
        let breakdown = WakeBreakdown([
            DarkWake(date: date, reason: .wireless, seconds: 5, holders: ["cloudd", "powerd"]),
            DarkWake(date: date + 60, reason: .wireless, seconds: 9, holders: ["cloudd"], apps: ["com.apple.Photos"]),
            DarkWake(date: date + 120, reason: .other),
        ])
        #expect(breakdown.secondsAwake == 14 && breakdown.timedWakes == 2)
        #expect(breakdown.holders.map(\.name) == ["cloudd", "powerd"])
        #expect(breakdown.holders.first?.count == 2)
        #expect(breakdown.apps.map(\.name) == ["com.apple.Photos"])
    }

    @Test func breaksWakesDownForSleeps() {
        let (wakes, _) = WakeLog.parse(Self.log)
        let start = ISO8601DateFormatter().date(from: "2026-10-24T00:23:10Z")!
        let first = SleepSession(start: start, end: start + 3 * 3600, startCapacity: 4000, endCapacity: 3990,
                                 fullChargeCapacity: 4500)
        let later = SleepSession(start: start + 3.5 * 3600, end: start + 5 * 3600, startCapacity: 4000,
                                 endCapacity: 3990, fullChargeCapacity: 4500)
        let during = WakeBreakdown.wakes(wakes, during: [later, first])
        #expect(during.count == 4)
        let breakdown = WakeBreakdown(during)
        #expect(breakdown.total == 4)
        #expect(breakdown.reasons.first?.count == 2)
        #expect(breakdown.reasons.map(\.reason) == [.scheduledTask, .networkUpkeep, .wireless])
        #expect(breakdown.tasks.map(\.name) == ["com.apple.acmd.alarm",
                                                "com.apple.intelligenceflow.toolbox.update.fastpass"])
        #expect(WakeBreakdown.wakes(wakes, during: []).isEmpty)
    }
}

@Suite struct AppEnergyTests {
    @Test func creditsHelpersToTheirApp() {
        #expect(AppEnergyMeter.appPath(containing:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/"
            + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
            == "/Applications/Google Chrome.app")
        #expect(AppEnergyMeter.appPath(containing: "/usr/libexec/nsurlsessiond") == "/usr/libexec/nsurlsessiond")
    }

    @Test func measuresThisProcessBetweenReadings() {
        var meter = AppEnergyMeter()
        #expect(meter.measure().isEmpty)
        // Some work, so this process has processor time to report.
        var total = 0.0
        for index in 0..<2_000_000 { total += sin(Double(index)) }
        #expect(total.isFinite)
        let usage = meter.measure()
        #expect(usage.values.allSatisfy { $0.joules >= 0 && $0.cpuSeconds >= 0 })
        #expect(usage.values.contains { $0.cpuSeconds > 0 })
    }

    @Test func countsProcessesStartedBetweenReadings() throws {
        var meter = AppEnergyMeter()
        _ = meter.measure()
        // A busy process started after the first reading, still running at the second.
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        defer { busy.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let usage = meter.measure()
        let owner = AppEnergyMeter.owner(of: busy.processIdentifier)
        #expect((usage[owner]?.cpuSeconds ?? 0) > 0.05)
    }

    @Test func storesHourlyTotals() throws {
        let store = try HistoryStore(url: nil)
        let hour = Date(timeIntervalSince1970: 1_792_000_800)
        try store.addAppUsage(["/A.app": AppUsage(joules: 100, cpuSeconds: 2)], at: hour, onBattery: true)
        try store.addAppUsage(["/A.app": AppUsage(joules: 50, cpuSeconds: 1),
                               "/B.app": AppUsage(joules: 10, cpuSeconds: 0.5)], at: hour + 600, onBattery: false)
        let usage = try store.appUsage(since: hour)
        let a = try #require(usage.first { $0.app == "/A.app" })
        #expect(a.total == AppUsage(joules: 150, cpuSeconds: 3))
        #expect(a.onBattery == AppUsage(joules: 100, cpuSeconds: 2))
        // Recorded by the hour; this time is on the hour.
        #expect(try store.appUsageStart() == hour)
        // Hours beyond the power timeline's retention are dropped.
        try store.addAppUsage(["/B.app": AppUsage(joules: 1)], at: hour + PowerTimeline.retention + 7200,
                              onBattery: false)
        #expect(try store.appUsage(since: .distantPast).first { $0.app == "/A.app" } == nil)
    }
}

@Suite struct SleepBlockerTests {
    static let now = Date(timeIntervalSince1970: 1_792_000_000)

    static func assertion(_ type: String, pid: Int32, process: String, name: String, age: TimeInterval,
                          behalf: Int32? = nil) -> [String: Any] {
        var assertion: [String: Any] = ["AssertType": type, "AssertPID": NSNumber(value: pid),
                                        "Process Name": process, "AssertName": name,
                                        "AssertStartWhen": now.addingTimeInterval(-age)]
        if let behalf { assertion["AssertionOnBehalfOfPID"] = NSNumber(value: behalf) }
        return assertion
    }

    @Test func namesAppsPreventingSleep() {
        let owners: [Int32: String] = [10: "/Applications/zoom.us.app", 11: "/Applications/Utilities/Terminal.app",
                                       12: "/Applications/Music.app", 20: "/usr/sbin/coreaudiod",
                                       30: "/System/Library/CoreServices/powerd.bundle/powerd"]
        let blockers = SleepBlockers.blockers(from: [
            Self.assertion("PreventUserIdleDisplaySleep", pid: 10, process: "zoom.us", name: "In a meeting", age: 600),
            Self.assertion("PreventUserIdleSystemSleep", pid: 10, process: "zoom.us", name: "com.zoom.call", age: 300),
            Self.assertion("PreventUserIdleSystemSleep", pid: 11, process: "caffeinate",
                           name: "caffeinate command-line tool", age: 120),
            Self.assertion("PreventUserIdleSystemSleep", pid: 20, process: "coreaudiod",
                           name: "com.apple.audio.context.preventuseridlesleep", age: 90, behalf: 12),
            // macOS's own, and passing ones, aren't listed.
            Self.assertion("PreventUserIdleSystemSleep", pid: 30, process: "powerd",
                           name: "Powerd - Prevent sleep while display is on", age: 3600),
            Self.assertion("PreventUserIdleSystemSleep", pid: 11, process: "backupd", name: "Backup", age: 20),
            Self.assertion("UserIsActive", pid: 10, process: "zoom.us", name: "active", age: 600),
        ], now: Self.now) { owners[$0] ?? "?" }
        #expect(blockers.map(\.owner) == ["/Applications/zoom.us.app", "/Applications/Utilities/Terminal.app",
                                          "/Applications/Music.app"])
        // Zoom keeps the Mac awake, not just the display, and says why in words.
        #expect(blockers[0].keepsDisplayOn == false && blockers[0].reason == "In a meeting")
        #expect(blockers[0].since == Self.now.addingTimeInterval(-600))
        // Its description only repeats the tool's name.
        #expect(blockers[1].process == "caffeinate" && blockers[1].reason == nil)
        #expect(blockers[2].reason == "Playing audio" && blockers[2].process == nil)
    }
}

@Suite struct PowerTimelinePassTests {
    @Test func briefWakesHandleOverlappingAndUnorderedInput() {
        let t = Date(timeIntervalSince1970: 1_792_000_000)
        func minute(_ offset: TimeInterval) -> PowerMinute {
            PowerMinute(start: t + offset, averageWatts: 2, peakWatts: 3, chargePercent: 50, onAdapter: false)
        }
        // A short sleep inside a long one, given out of order, and minutes out of order.
        let sleeps = [DateInterval(start: t + 600, duration: 300), DateInterval(start: t, duration: 7200)]
        let wakes = PowerTimeline.briefWakes([minute(3600), minute(660), minute(-120), minute(7200)], sleeps: sleeps)
        // Inside: 660 (both sleeps) and 3600 (the long one). Outside: before it, and at its end.
        #expect(wakes.map(\.start) == [t + 660, t + 3600])
    }
}

@Suite struct AppEnergyPeriodTests {
    @Test func hourSelectionUsesRecentReadings() {
        let selected = AppEnergyPeriod.hour
        #expect(selected.duration == 3600)
        #expect(selected.usesRecentReadings)
        #expect(!AppEnergyPeriod.day.usesRecentReadings)
        #expect(!AppEnergyPeriod.week.usesRecentReadings)
        #expect(!AppEnergyPeriod.month.usesRecentReadings)
    }
}
