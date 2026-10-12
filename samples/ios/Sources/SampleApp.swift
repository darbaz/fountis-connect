import SwiftUI
import FountisConnect

@main
struct SampleApp: App {
    init() {
        // At launch, before the app finishes launching: this also registers the background refresh task.
        FountisConnect.start(key: SampleConfig.key, apiBase: URL(string: SampleConfig.apiBase))
        FountisConnect.setUserToken { await SampleSession.shared.token() }
        FountisConnect.enableNotifications()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Stands in for the partner's own sign-in. A real app asks its server for a signed token
/// (see samples/server-node); this sandbox sample makes an unsigned one for a fake user.
actor SampleSession {
    static let shared = SampleSession()
    private var signedIn = true

    func setSignedIn(_ v: Bool) { signedIn = v }
    func isSignedIn() -> Bool { signedIn }

    func token() -> String? {
        guard signedIn else { return nil }
        func b64(_ o: [String: Any]) -> String {
            let d = try! JSONSerialization.data(withJSONObject: o)
            return d.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        let iat = Int(Date().timeIntervalSince1970)
        let year = Calendar.current.component(.year, from: Date())
        let payload: [String: Any] = [
            "iss": SampleConfig.partnerId, "aud": "fountis-connect:\(SampleConfig.appId)",
            "sub": "sandbox_user_0001_AAAAAAAAAAAAAAAA", "kyc": "verified",
            "attrs": ["gender": "female", "birth_year": year - 33, "governorate": "erbil", "city": "erbil", "lang": "en"],
            "mapping_version": 1, "iat": iat, "exp": iat + 3600, "jti": UUID().uuidString,
        ]
        return b64(["alg": "none", "typ": "JWT"]) + "." + b64(payload) + "."
    }
}
