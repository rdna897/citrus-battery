import CPowerUI
import Darwin
import Foundation

/// Everything that may be holding the battery below a full charge.
public struct ChargeLimitStatus: Sendable, Equatable {
    /// macOS Charge Limit percentage, when the user has enabled one.
    public var macOSLimitPercent: Int?
    public var optimizedChargingEnabled: Bool
    /// Optimized Battery Charging is currently holding the charge (usually at 80%).
    public var optimizedChargingEngaged: Bool
    /// Names of third-party charge limiters found running, e.g. "AlDente".
    public var thirdPartyLimiters: [String]
    /// An Intel `BCLM` maximum charge level written to the SMC by a limiter.
    public var smcChargeLevelLimit: Int?

    public init(macOSLimitPercent: Int? = nil, optimizedChargingEnabled: Bool = false,
                optimizedChargingEngaged: Bool = false, thirdPartyLimiters: [String] = [],
                smcChargeLevelLimit: Int? = nil) {
        self.macOSLimitPercent = macOSLimitPercent
        self.optimizedChargingEnabled = optimizedChargingEnabled
        self.optimizedChargingEngaged = optimizedChargingEngaged
        self.thirdPartyLimiters = thirdPartyLimiters
        self.smcChargeLevelLimit = smcChargeLevelLimit
    }

    /// Some limit other than macOS's own is in force. macOS's Charge Limit and
    /// Optimized Charging occasionally charge to 100% to keep the gauge
    /// calibrated; third-party limiters don't do that on their own.
    public var hasThirdPartyLimit: Bool {
        !thirdPartyLimiters.isEmpty || smcChargeLevelLimit != nil
    }

    public var isLimiting: Bool {
        macOSLimitPercent != nil || optimizedChargingEngaged || hasThirdPartyLimit
    }
}

/// Advice shown alongside a charge limit.
public struct ChargeLimitAdvice: Sendable, Equatable {
    public enum Level: Sendable { case info, caution }
    public var level: Level
    public var message: String

    public init(level: Level, message: String) {
        self.level = level
        self.message = message
    }
}

extension ChargeLimitStatus {
    /// Explains the limit's effect on reported capacity.
    ///
    /// - Parameter cyclesSinceCalibration: cycles since the gauge last updated its
    ///   capacity estimate (`CycleCount − LifetimeData.CycleCountLastQmax`).
    public func advice(cyclesSinceCalibration: Int?) -> ChargeLimitAdvice? {
        if hasThirdPartyLimit {
            let who = thirdPartyLimiters.first.map { "\($0) is" } ?? "Another app is"
            var message = "\(who) limiting charging. Weeks below full can throw off the gauge, so maximum "
                + "capacity reads lower than it is (a measuring error, not wear). Charge to 100% now and "
                + "then; AlDente's developers suggest a full cycle every two weeks."
            if let cycles = cyclesSinceCalibration {
                message += " The gauge last recalibrated \(cycles) cycle\(cycles == 1 ? "" : "s") ago."
            }
            return ChargeLimitAdvice(level: .caution, message: message)
        }
        if macOSLimitPercent != nil || optimizedChargingEngaged {
            return ChargeLimitAdvice(
                level: .info,
                message: "macOS occasionally charges to 100% to keep its estimates accurate, so this "
                    + "limit doesn't affect reported capacity."
            )
        }
        return nil
    }
}

public enum ChargeLimitReader {
    /// Reads current charging policy. Performs synchronous XPC and process
    /// enumeration; call off the main thread.
    public static func read(smc: SMCReading? = SMC.shared) -> ChargeLimitStatus {
        var policy = cpowerui_status()
        cpowerui_read_status(&policy)

        var status = ChargeLimitStatus()
        if policy.available {
            if policy.charge_limit_enabled, policy.charge_limit_percent > 0, policy.charge_limit_percent < 100 {
                status.macOSLimitPercent = Int(policy.charge_limit_percent)
            }
            status.optimizedChargingEnabled = policy.optimized_enabled
            status.optimizedChargingEngaged = policy.optimized_engaged
        }
        status.thirdPartyLimiters = runningLimiters()

        // Intel: BCLM holds the maximum charge percentage (100 = no limit). The
        // Apple silicon charge-inhibit keys are also set by macOS itself, so they
        // can't attribute a limit to another app and aren't used here.
        if let level = smc?.double("BCLM").map({ Int($0) }), level > 0, level < 100 {
            status.smcChargeLevelLimit = level
        }
        return status
    }

    /// Known third-party charge limiters, matched against running executables.
    private static let knownLimiters: [(name: String, matches: @Sendable (String) -> Bool)] = [
        ("AlDente", { $0.localizedCaseInsensitiveContains("aldente") }),
        ("Battery Toolkit", { $0.contains("BatteryToolkit") || $0.contains("Battery Toolkit") || $0.contains("me.mhaeuser.batteryt") }),
        ("batt", { ($0 as NSString).lastPathComponent == "batt" }),
    ]

    static func runningLimiters() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        var found = Set<String>()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            for limiter in knownLimiters where limiter.matches(path) {
                found.insert(limiter.name)
            }
        }
        return knownLimiters.map(\.name).filter(found.contains)
    }
}
