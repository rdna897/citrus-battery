import CitrusKit
import Combine
import Foundation
import UserNotifications

/// Posts battery notifications based on the user's alert settings.
@MainActor
final class Notifier: NSObject, ObservableObject {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private var state = BatteryAlertState()
    private var readingObserver: AnyCancellable?

    /// UNUserNotificationCenter needs an app bundle; it traps when run as a bare binary.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil

    init(monitor: BatteryMonitor) {
        super.init()
        center?.delegate = self
        readingObserver = monitor.$battery
            .compactMap { $0 }
            .sink { [weak self] battery in self?.evaluate(battery) }
        refreshAuthorization()
    }

    var isAvailable: Bool { center != nil }

    func refreshAuthorization() {
        center?.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in self?.authorization = status }
        }
    }

    /// Asks for permission the first time an alert is enabled.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor [weak self] in self?.refreshAuthorization() }
        }
    }

    func sendTest() {
        requestAuthorization()
        post(title: "Citrus Battery", body: "This is how Citrus Battery will notify you.")
    }

    private func evaluate(_ battery: MacBatterySnapshot) {
        guard let fraction = battery.chargeFraction(style: .apple) else { return }
        let reading = BatteryReading(
            chargePercent: Int((fraction * 100).rounded()),
            timeToEmptyMinutes: battery.isExternalPowerConnected ? nil : battery.timeRemainingMinutes,
            isExternalPowerConnected: battery.isExternalPowerConnected,
            isFullyCharged: battery.isFullyCharged
        )
        let (alerts, next) = BatteryAlertRules.evaluate(reading, settings: UserDefaults.standard.batteryAlertSettings,
                                                        state: state)
        state = next
        for alert in alerts {
            post(title: alert.title, body: alert.body)
        }
    }

    private func post(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show banners even while Citrus Battery is the frontmost app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
