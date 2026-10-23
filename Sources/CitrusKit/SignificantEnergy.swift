import Foundation

/// An app macOS lists under "Using Significant Energy" in its battery menu.
public struct SignificantEnergyApp: Sendable, Equatable, Identifiable {
    /// The app responsible for the work, e.g. a browser for its helper processes.
    public var bundleIdentifier: String
    /// The name macOS gives, when it gives one.
    public var displayName: String?
    /// macOS's energy impact over the report period (unitless, as in Activity Monitor).
    public var energyImpact: Double

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String? = nil, energyImpact: Double) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.energyImpact = energyImpact
    }
}

/// Reads the list from `systemstats_get_top_coalitions` in libsystemstats, the
/// private call macOS's battery menu (ControlCenter) makes, with its arguments:
/// the last 120 seconds, at most 5 apps, and an energy impact above 500 per second.
public enum SignificantEnergy {
    static let reportSeconds: UInt64 = 120
    static let maximumApps: UInt64 = 5
    static let impactPerSecond = 500.0

    /// Highest impact first; empty when nothing qualifies, nil when the call is unavailable.
    public static func read() -> [SignificantEnergyApp]? {
        typealias TopCoalitions = @convention(c) (UInt64, UInt64, Double) -> Unmanaged<AnyObject>?
        guard let handle = dlopen("/usr/lib/libsystemstats.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "systemstats_get_top_coalitions")
        else { return nil }
        let topCoalitions = unsafeBitCast(symbol, to: TopCoalitions.self)
        let report = topCoalitions(reportSeconds, maximumApps, Double(reportSeconds) * impactPerSecond)?
            .takeUnretainedValue() as? [String: Any]
        return report.map(apps(from:)) ?? []
    }

    /// Parses the report: parallel arrays of bundle IDs, responsible bundle IDs,
    /// display names and energy impacts (numbers or numeric strings).
    static func apps(from report: [String: Any]) -> [SignificantEnergyApp] {
        let bundles = report["bundle_identifiers"] as? [String] ?? []
        let responsible = report["responsible_bundle_identifiers"] as? [String] ?? []
        let names = report["display_names"] as? [String] ?? []
        let impacts = report["energy_impacts"] as? [Any] ?? []

        var apps: [SignificantEnergyApp] = []
        for (index, bundle) in bundles.enumerated() {
            let owner = responsible.indices.contains(index) && !responsible[index].isEmpty ? responsible[index] : bundle
            guard !owner.isEmpty else { continue }
            let impact = impacts.indices.contains(index) ? number(impacts[index]) ?? 0 : 0
            let name = names.indices.contains(index) && !names[index].isEmpty ? names[index] : nil
            if let existing = apps.firstIndex(where: { $0.bundleIdentifier == owner }) {
                apps[existing].energyImpact += impact
                apps[existing].displayName = apps[existing].displayName ?? name
            } else {
                apps.append(SignificantEnergyApp(bundleIdentifier: owner, displayName: name, energyImpact: impact))
            }
        }
        return apps.sorted { $0.energyImpact > $1.energyImpact }
    }

    private static func number(_ value: Any) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }
}
