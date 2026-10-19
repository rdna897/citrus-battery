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
