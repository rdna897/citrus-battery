import CitrusKit
import Combine
import Foundation

struct PowerSample: Identifiable, Equatable {
    let date: Date
    let systemWatts: Double

    var id: Date { date }
}

/// Polls the Mac's battery and SMC and publishes the latest readings.
@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var battery: MacBatterySnapshot?
    @Published private(set) var power = PowerReadings()
    @Published private(set) var macInfo = MacInfo.read()
    @Published private(set) var marketingName: String?
    /// System power over the last two minutes, for the chart.
    @Published private(set) var powerHistory: [PowerSample] = []

    private var timer: Timer?
    private var interval: UpdateInterval
    private var defaultsObserver: AnyCancellable?

    /// How far back "Delayed" mode averages power values.
    private static let smoothingWindow: TimeInterval = 30
    private static let historyWindow: TimeInterval = 120

    init() {
        interval = UserDefaults.standard.updateInterval
        refresh()
        schedule()

        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIntervalIfChanged() }

        Task.detached(priority: .utility) {
            let name = MacInfo.marketingName()
            await MainActor.run { [weak self] in self?.marketingName = name }
        }
    }

    /// Highest system power in the last minute.
    var maxSystemWattsLastMinute: Double? {
        let cutoff = Date().addingTimeInterval(-60)
        return powerHistory.filter { $0.date >= cutoff }.map(\.systemWatts).max()
    }

    /// System power to display: averaged in Delayed mode, latest in Fast mode.
    var displayedSystemWatts: Double? {
        guard interval == .delayed else { return power.systemWatts }
        let cutoff = Date().addingTimeInterval(-Self.smoothingWindow)
        let recent = powerHistory.filter { $0.date >= cutoff }.map(\.systemWatts)
        guard !recent.isEmpty else { return power.systemWatts }
        return recent.reduce(0, +) / Double(recent.count)
    }

    func refresh() {
        battery = MacBatteryReader.read()
        power = PowerReadings.read()

        let now = Date()
        if let watts = power.systemWatts {
            powerHistory.append(PowerSample(date: now, systemWatts: watts))
        }
        powerHistory.removeAll { $0.date < now.addingTimeInterval(-Self.historyWindow) }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval.seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func updateIntervalIfChanged() {
        let latest = UserDefaults.standard.updateInterval
        guard latest != interval else { return }
        interval = latest
        schedule()
    }
}
