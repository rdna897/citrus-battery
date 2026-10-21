import CitrusKit
import Combine
import Foundation
import UserNotifications

/// Posts battery notifications based on the user's alert settings.
@MainActor
final class Notifier: NSObject, ObservableObject {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private var state = BatteryAlertState()
    private var observers: [AnyCancellable] = []
    /// Per-device arming for the "charged to X%" alert, keyed by UDID.
    private var deviceAlertArmed: [String: Bool] = [:]

    /// UNUserNotificationCenter needs an app bundle; it traps when run as a bare binary.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil

    init(monitor: BatteryMonitor, iosDevices: IOSDeviceMonitor) {
        super.init()
        center?.delegate = self
        observers.append(monitor.$battery
            .compactMap { $0 }
            .sink { [weak self] battery in self?.evaluate(battery) })
        observers.append(iosDevices.$devices
            .sink { [weak self] devices in self?.evaluate(devices) })
        refreshAuthorization()
    }

    private func evaluate(_ devices: [TrackedDevice]) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PreferenceKey.alertDeviceChargeEnabled) else { return }
        let threshold = defaults.object(forKey: PreferenceKey.alertDeviceChargePercent) as? Int ?? 80
        for device in devices where device.state == .ready {
            guard let battery = device.snapshot?.battery,
                  let fraction = battery.chargeFraction(style: .apple) else { continue }
            let percent = Int((fraction * 100).rounded())
            // First reading of a device only sets the arming, so launching or
            // plugging in a device that's already above the level stays quiet.
            guard deviceAlertArmed[device.udid] != nil else {
                deviceAlertArmed[device.udid] = percent < threshold
                continue
            }
            let result = DeviceChargeAlertRule.evaluate(
                percent: percent, isCharging: battery.isCharging, threshold: threshold,
                armed: deviceAlertArmed[device.udid] ?? true)
            deviceAlertArmed[device.udid] = result.armed
            if result.notify {
                let message = DeviceChargeAlertRule.message(deviceName: device.displayName, percent: percent)
                post(title: message.title, body: message.body)
            }
        }
    }

    var isAvailable: Bool { center != nil }

    func refreshAuthorization() {
        // Older SDKs don't mark UNNotificationSettings as Sendable. Read its
        // status in a nonisolated callback and transfer only that enum to the UI.
        center?.getNotificationSettings { @Sendable [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                self?.authorization = status
                if ProcessInfo.processInfo.environment["CITRUS_GUI_SMOKE_TEST"] == "1" {
                    print("Citrus notification settings check passed")
                }
            }
        }
    }

    /// Asks for permission the first time an alert is enabled.
    func requestAuthorization() {
        guard let center else { return }
        Task { @MainActor [weak self] in
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            self?.refreshAuthorization()
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
