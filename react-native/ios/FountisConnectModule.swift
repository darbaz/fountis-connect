import ExpoModulesCore
import UIKit

/// JS bridge for the FOUNTIS Connect iOS SDK. All SDK calls run on the main thread, in the order JS made them.
public final class FountisConnectModule: Module {
    private let tokens = TokenRequests()

    public func definition() -> ModuleDefinition {
        Name("FountisConnect")

        Events("onFountisEvent", "onTokenRequest")

        OnCreate {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    FountisConnect.onEvent { [weak self] e in
                        var body: [String: Any] = ["type": e.type]
                        if let id = e.offerId { body["offerId"] = id }
                        self?.sendEvent("onFountisEvent", body)
                    }
                }
            }
        }

        Function("start") { (key: String, apiBase: String?) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    FountisConnect.start(key: key, apiBase: apiBase.flatMap { URL(string: $0) })
                }
            }
        }

        // JS owns the token function. The SDK asks for a token; we ask JS with an event and wait for resolveToken.
        Function("setTokenProviderEnabled") { (enabled: Bool) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard enabled else { return }
                    FountisConnect.setUserToken { [weak self] in
                        // A vanished bridge is a failure, not "signed out": throwing keeps the person off the guest path.
                        guard let self else { throw TokenBridgeError.bridgeGone }
                        return try await self.tokens.request { id in self.sendEvent("onTokenRequest", ["id": id]) }
                    }
                }
            }
        }

        Function("resolveToken") { (id: String, token: String?) in
            self.tokens.resolve(id, token)
        }

        // The JS token function threw or rejected: tell the SDK the token is unavailable (not that nobody is signed in).
        Function("rejectToken") { (id: String) in
            self.tokens.reject(id)
        }

        Function("enableNotifications") {
            DispatchQueue.main.async { MainActor.assumeIsolated { FountisConnect.enableNotifications() } }
        }

        Function("setUserConsent") { (granted: Bool) in
            DispatchQueue.main.async { MainActor.assumeIsolated { FountisConnect.setUserConsent(granted) } }
        }

        Function("signOut") {
            DispatchQueue.main.async { MainActor.assumeIsolated { FountisConnect.signOut() } }
        }

        AsyncFunction("show") { () async -> String in
            let r = await FountisConnect.show()
            switch r {
            case .completed: return "completed"
            case .dismissed: return "dismissed"
            case .noFill: return "noFill"
            }
        }

        AsyncFunction("handlePush") { (data: [String: String]) async -> Bool in
            await MainActor.run { FountisConnect.handlePush(data) }
        }
    }
}

/// Why a token request did not produce an answer. The SDK treats any thrown error as "no session" (noFill),
/// which is different from a nil token (nobody is signed in, so guest studies when the app allows them).
enum TokenBridgeError: Error {
    case providerFailed
    case timedOut
    case bridgeGone
}

/// Pending "give me a token" questions to JS. Each one is answered once: with the token (nil means nobody is signed in),
/// with a thrown error when the JS function failed, or with `timedOut` after 10 seconds (for example when the JS side is
/// not running during a background refresh).
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

    func resolve(_ id: String, _ token: String?) {
        finish(id, .success(token))
    }

    func reject(_ id: String) {
        finish(id, .failure(TokenBridgeError.providerFailed))
    }

    /// Resumes the request once; a late or repeated answer finds nothing pending and does nothing.
    private func finish(_ id: String, _ result: Result<String?, Error>) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(with: result)
    }
}
