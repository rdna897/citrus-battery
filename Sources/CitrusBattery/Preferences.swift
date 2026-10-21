import CitrusKit
import Foundation
import SwiftUI

/// UserDefaults keys, shared by `@AppStorage` and non-view code.
enum PreferenceKey {
    static let temperatureUnit = "temperatureUnit"
    static let capacityUnit = "capacityUnit"
    static let capacityStyle = "capacityStyle"
    static let updateInterval = "updateInterval"
    static let autosaveNewDevices = "autosaveNewDevices"

    static let showInMenuBar = "showInMenuBar"
    static let menuBarFormat = "menuBarFormat"
    static let batterySymbol = "batterySymbol"
    static let menuBarAccentColour = "menuBarAccentColour"
    static let showDockIcon = "showDockIcon"

    static let alertLowChargeEnabled = "alertLowChargeEnabled"
    static let alertLowChargePercent = "alertLowChargePercent"
    static let alertLowTimeEnabled = "alertLowTimeEnabled"
    static let alertLowTimeMinutes = "alertLowTimeMinutes"
    static let alertFullyCharged = "alertFullyCharged"
}

/// Where the battery icon sits next to the menu bar text.
enum BatterySymbolPosition: String, CaseIterable, Identifiable {
    case none, left, right

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

extension UserDefaults {
    var batteryAlertSettings: BatteryAlertSettings {
        BatteryAlertSettings(
            lowChargePercent: bool(forKey: PreferenceKey.alertLowChargeEnabled)
                ? (object(forKey: PreferenceKey.alertLowChargePercent) as? Int ?? 20) : nil,
            lowTimeMinutes: bool(forKey: PreferenceKey.alertLowTimeEnabled)
                ? (object(forKey: PreferenceKey.alertLowTimeMinutes) as? Int ?? 30) : nil,
            fullyCharged: bool(forKey: PreferenceKey.alertFullyCharged)
        )
    }
}

/// Which part of the main window is showing; shared so the menu bar can open History.
@MainActor
final class Navigator: ObservableObject {
    @Published var selection: SidebarItem? = .thisMac
}

extension UserDefaults {
    var updateInterval: UpdateInterval {
        string(forKey: PreferenceKey.updateInterval).flatMap(UpdateInterval.init(rawValue:)) ?? .delayed
    }
}

/// The macOS 27 SDK resolves `@State` to a macro whose plugin ships only with
/// full Xcode. This alias names the underlying property wrapper directly so the
/// project also builds with the Command Line Tools.
typealias ViewState = SwiftUI.State
