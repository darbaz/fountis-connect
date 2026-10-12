import Flutter
import UIKit

/// MethodChannel bridge for the FOUNTIS Connect iOS SDK. Flutter calls plugins on the main thread.
public final class FountisConnectPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private let tokens = TokenRequests()

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "org.fountis.connect/methods", binaryMessenger: registrar.messenger())
        let instance = FountisConnectPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)

        MainActor.assumeIsolated {
            FountisConnect.onEvent { [weak instance] e in
                var body: [String: Any] = ["type": e.type]
                if let id = e.offerId { body["offerId"] = id }
                instance?.channel.invokeMethod("event", arguments: body)
            }
            // Optional: with `FountisConnectKey` in Info.plist the SDK starts while the app is still launching,
            // which iOS requires for the background refresh. Without it, start() from Dart still works.
            let info = Bundle.main.infoDictionary ?? [:]
            if let key = info["FountisConnectKey"] as? String, !key.isEmpty {
                FountisConnect.start(key: key, apiBase: (info["FountisConnectApiBase"] as? String).flatMap { URL(string: $0) })
            }
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "start":
            if let key = args?["key"] as? String {
                MainActor.assumeIsolated {
                    FountisConnect.start(key: key, apiBase: (args?["apiBase"] as? String).flatMap { URL(string: $0) })
                }
            }
            result(nil)

        case "setTokenProviderEnabled":
            if (call.arguments as? Bool) == true {
                MainActor.assumeIsolated {
                    FountisConnect.setUserToken { [weak self] in
                        // A vanished bridge is a failure, not "signed out": nil would send a signed-in person down the guest path.
                        guard let self else { throw TokenBridgeError.bridgeGone }
                        return try await self.tokens.request { id in
                            DispatchQueue.main.async { self.channel.invokeMethod("tokenRequest", arguments: id) }
                        }
                    }
                }
            }
            result(nil)

        case "resolveToken":
            if let id = args?["id"] as? String { tokens.resolve(id, args?["token"] as? String) }
            result(nil)

        case "rejectToken":
            // Dart's token function threw: the SDK gets an error (nothing is shown), not a nil token (a guest).
            if let id = call.arguments as? String { tokens.reject(id) }
            result(nil)

        case "enableNotifications":
            MainActor.assumeIsolated { FountisConnect.enableNotifications() }
            result(nil)

        case "show":
            Task { @MainActor in
                switch await FountisConnect.show() {
                case .completed: result("completed")
                case .dismissed: result("dismissed")
                case .noFill: result("noFill")
                }
            }

        case "handlePush":
            let data = (call.arguments as? [String: Any]) ?? [:]
            result(MainActor.assumeIsolated { FountisConnect.handlePush(data) })

        case "setUserConsent":
            MainActor.assumeIsolated { FountisConnect.setUserConsent((call.arguments as? Bool) ?? true) }
            result(nil)

        case "signOut":
            MainActor.assumeIsolated { FountisConnect.signOut() }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// Why a token request has no answer. Each one means "could not tell who is signed in", which is different from
/// "nobody is signed in" (a nil token). The SDK maps a thrown error to no study, and nil to the guest path.
enum TokenBridgeError: Error {
    case providerFailed
    case timedOut
    case bridgeGone
}

/// Pending "give me a token" questions to Dart. Each one is answered once: with a token (or nil for signed out),
/// with an error when Dart's token function threw, or with an error after the timeout (for example when Dart is not
/// running during a background refresh).
final class TokenRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<String?, Error>] = [:]
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    func request(send: @escaping (String) -> Void) async throws -> String? {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            lock.lock()
            pending[id] = cont
            lock.unlock()
            send(id)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(id, .failure(TokenBridgeError.timedOut))
            }
        }
    }

    func resolve(_ id: String, _ token: String?) { finish(id, .success(token)) }

    func reject(_ id: String) { finish(id, .failure(TokenBridgeError.providerFailed)) }

    private func finish(_ id: String, _ outcome: Result<String?, Error>) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(with: outcome)
    }
}
