import ExpoModulesCore
import UIKit

/// Starts the SDK while the app is still launching when the config plugin was given a key
/// (`FountisConnectKey` in Info.plist). iOS only accepts the background refresh registration at that moment.
/// Without a key here, `start()` from JS still works; only the background refresh is not registered.
public final class FountisConnectAppDelegateSubscriber: ExpoAppDelegateSubscriber {
    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        if let key = info["FountisConnectKey"] as? String, !key.isEmpty {
            let base = (info["FountisConnectApiBase"] as? String).flatMap { URL(string: $0) }
            MainActor.assumeIsolated { FountisConnect.start(key: key, apiBase: base) }
        }
        return true
    }
}
