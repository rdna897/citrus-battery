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
