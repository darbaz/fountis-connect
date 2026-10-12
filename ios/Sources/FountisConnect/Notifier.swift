import Foundation
import UIKit
import BackgroundTasks
import UserNotifications

/// Forwards notification callbacks to the SDK. Installed only when the host app has no delegate of its own.
final class ForwardingNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            _ = FountisConnect.handleNotificationResponse(response)
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

enum BGRefresh {
    static let identifier = "org.fountis.connect.refresh"
    /// Submitting a request without a registered handler raises an Objective-C exception, so only schedule after register.
    nonisolated(unsafe) private(set) static var registered = false

    /// Must run before the host app finishes launching. Never throws: a missing Info.plist entry only logs.
    @MainActor
    static func register(handler: @escaping @MainActor () async -> Void) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let ids = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        guard ids.contains(identifier), modes.contains("fetch") else {
            fcLog.debug("background refresh not set up: add \(identifier) to BGTaskSchedulerPermittedIdentifiers and 'fetch' to UIBackgroundModes")
            return false
        }
        // register(...) raises an Objective-C exception once launch has finished. A scene that is already
        // connected means launch is over (applicationState is not reliable this early).
        if UIApplication.shared.connectedScenes.contains(where: { $0.activationState != .unattached }) {
            fcLog.debug("start() ran after launch finished; background refresh not registered")
            return false
        }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in
                schedule(minutes: nil)
                let work = Task { @MainActor in
                    await handler()
                    task.setTaskCompleted(success: true)
                }
                task.expirationHandler = {
                    work.cancel()
                    task.setTaskCompleted(success: false)
                }
            }
        }
        return registered
    }

    static func schedule(minutes: Int?) {
        guard registered else { return }
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: Double(max(minutes ?? 240, 60)) * 60)
        do { try BGTaskScheduler.shared.submit(req) } catch { fcLog.debug("could not schedule refresh: \(error.localizedDescription)") }
    }
}
