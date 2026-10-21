import CryptoKit
import Foundation
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

    @Test func estimateMatchesCoconutBattery() {
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

    @Test func devicesAndSmartSave() throws {
        let store = try HistoryStore(url: nil)
        try store.insert(Self.entry(19))
        try store.insert(Self.entry(20))
        try store.insert(Self.entry(18, serial: "PHONE"))
        var devices = try store.devices(defaultSmartSave: true)
        #expect(devices.map(\.serial) == ["MAC1", "PHONE"])
        #expect(devices.first?.entryCount == 2)
        let allSmartSave = devices.allSatisfy(\.smartSave)
        #expect(allSmartSave)

        try #expect(store.smartSave(deviceSerial: "MAC1") == nil)
        try store.setSmartSave(false, deviceSerial: "MAC1")
        try #expect(store.smartSave(deviceSerial: "MAC1") == false)
        devices = try store.devices(defaultSmartSave: true)
        #expect(devices.first?.smartSave == false)
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
        try #expect(target.importBackup(backup) == 1)
        try #expect(target.entries().count == 2)
        try #expect(target.importBackup(backup) == 0)
        #expect(throws: HistoryError.self) { try target.importBackup(Data("{}".utf8)) }
    }

    @Test func smartSaveDuplicateRule() {
        let calendar = ManufactureDateTests.utc
        let saved = [Self.entry(19, hour: 9)]
        // Same day, same cycles, capacity within 5% → duplicate.
        #expect(SmartSavePolicy.isDuplicate(Self.entry(19, hour: 20, fcc: 4700), of: saved, calendar: calendar))
        // Capacity moved more than 5%.
        #expect(!SmartSavePolicy.isDuplicate(Self.entry(19, hour: 20, fcc: 4200), of: saved, calendar: calendar))
        // New cycle.
        #expect(!SmartSavePolicy.isDuplicate(Self.entry(19, hour: 20, cycles: 47), of: saved, calendar: calendar))
        // Next day.
        #expect(!SmartSavePolicy.isDuplicate(Self.entry(20, hour: 9), of: saved, calendar: calendar))
    }
}

@Suite struct CoconutBatteryImportTests {
    /// Builds a backup the way coconutBattery does: JSON → LZFSE → AES-GCM.
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
