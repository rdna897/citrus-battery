import Darwin
import Foundation

/// Energy and processor time an app used over a span.
public struct AppUsage: Sendable, Equatable {
    /// Processor energy, from the kernel's per-process estimate (Apple silicon;
    /// zero on Intel Macs, which don't measure it).
    public var joules: Double
    public var cpuSeconds: Double

    public init(joules: Double = 0, cpuSeconds: Double = 0) {
        self.joules = joules
        self.cpuSeconds = cpuSeconds
    }

    public static func + (lhs: AppUsage, rhs: AppUsage) -> AppUsage {
        AppUsage(joules: lhs.joules + rhs.joules, cpuSeconds: lhs.cpuSeconds + rhs.cpuSeconds)
    }
}

/// Measures how much energy each app uses, by reading every process's
/// running totals and crediting the difference since the last reading to the
/// app responsible for it, so helpers count towards their app, as in Activity
/// Monitor. Reading every process takes a few milliseconds and needs no
/// administrator rights, though processes macOS runs as root can't be read.
public struct AppEnergyMeter {
    /// A process, told apart from a later one given the same ID by its start time.
    private struct ProcessKey: Hashable {
        var pid: pid_t
        var started: UInt64
    }

    private var last: [ProcessKey: (usage: AppUsage, owner: String)] = [:]
    /// When the previous reading was taken (mach absolute time), or nil before the first.
    private var lastReading: UInt64?

    public init() {}

    /// Usage per app since the previous call, by app path (or executable path
    /// for processes outside an app). Empty on the first call. A process that
    /// starts and exits between two calls isn't seen, so its use isn't counted.
    public mutating func measure() -> [String: AppUsage] {
        var current: [ProcessKey: (usage: AppUsage, owner: String)] = [:]
        var result: [String: AppUsage] = [:]
        let previousReading = lastReading
        lastReading = mach_absolute_time()
        for (pid, info) in Self.readAll() {
            let key = ProcessKey(pid: pid, started: info.ri_proc_start_abstime)
            let usage = AppUsage(joules: Double(info.ri_energy_nj) / 1e9,
                                 cpuSeconds: Double(info.ri_user_time + info.ri_system_time) * Self.secondsPerTick)
            guard let previous = last[key] else {
                let owner = Self.owner(of: pid)
                current[key] = (usage, owner)
                // Started since the last reading: everything it has used is from
                // this span. Otherwise it was running before the first reading,
                // so its totals so far aren't.
                if let previousReading, info.ri_proc_start_abstime > previousReading,
                   usage.joules > 0 || usage.cpuSeconds > 0 {
                    result[owner, default: AppUsage()] = result[owner, default: AppUsage()] + usage
                }
                continue
            }
            current[key] = (usage, previous.owner)
            let delta = AppUsage(joules: max(usage.joules - previous.usage.joules, 0),
                                 cpuSeconds: max(usage.cpuSeconds - previous.usage.cpuSeconds, 0))
            if delta.joules > 0 || delta.cpuSeconds > 0 {
                result[previous.owner, default: AppUsage()] = result[previous.owner, default: AppUsage()] + delta
            }
        }
        last = current
        return result
    }

    /// Processor times are in mach ticks: nanoseconds on Intel, but 1/24 MHz on
    /// Apple silicon.
    static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(max(timebase.denom, 1)) / 1e9
    }()

    private static func readAll() -> [(pid_t, rusage_info_v6)] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(count, 0)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            return status == 0 ? (pid, info) : nil
        }
    }

    /// The app a process belongs to, by path: "/Applications/Google Chrome.app"
    /// for any of Chrome's helpers.
    public static func owner(of pid: pid_t) -> String {
        let responsible = responsiblePID?(pid) ?? pid
        let path = executablePath(responsible > 0 ? responsible : pid) ?? executablePath(pid) ?? "pid \(pid)"
        return appPath(containing: path)
    }

    /// The outermost app bundle in a path, or the path itself.
    static func appPath(containing path: String) -> String {
        guard let range = path.range(of: ".app/") else { return path }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process macOS holds responsible for another, as Activity Monitor
    /// groups them; a private but long-standing libsystem call.
    nonisolated(unsafe) private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
    }()
}
