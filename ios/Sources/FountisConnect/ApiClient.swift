import Foundation

struct APIError: Error {
    let status: Int
    let code: String
    let message: String
    /// The reply's optional `reason` field (for example `unknown_key` on `attest_invalid`); empty when absent.
    var reason: String = ""

    /// Errors that end the attempt for good (the engine shows the matching screen).
    var isFatal: Bool { ["invalid_token", "not_eligible", "already_taken", "closed", "quota_full"].contains(code) }
}

/// Thin client for the connect-api. Own ephemeral session; only the headers the contract names.
///
/// Every request has a total deadline (`requestDeadline`, 15 s): connection, request and the whole response body. When it
/// passes the call fails with `URLError(.timedOut)`, the same error a URLSession timeout raises, so it ends as `noFill`
/// the way a timeout always did.
final class ApiClient: Sendable {
    let base: URL
    let key: String
    let session: URLSession
    /// Total time one request may take (see `requestDeadline`).
    let deadline: TimeInterval

    /// `deadline` and `protocolClasses` exist for tests (a shortened deadline, a stubbed network); the SDK passes neither.
    init(base: URL, key: String, deadline: TimeInterval = requestDeadline, protocolClasses: [AnyClass]? = nil) {
        self.base = base
        self.key = key
        self.deadline = deadline
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Idle limit (restarts whenever bytes arrive): kept at the deadline so no single wait can outlast it.
        cfg.timeoutIntervalForRequest = deadline
        // Total limit for the whole transfer. The deadline in `request` is the one that is relied on; this is the second line.
        cfg.timeoutIntervalForResource = deadline
        cfg.waitsForConnectivity = false
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        session = URLSession(configuration: cfg)
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil, attemptToken: String? = nil) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw APIError(status: 0, code: "bad_url", message: "bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = deadline
        req.setValue(key, forHTTPHeaderField: "X-Fountis-Key")
        if let t = attemptToken { req.setValue("Attempt \(t)", forHTTPHeaderField: "Authorization") }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Connection, request and the whole body must finish within the deadline; a body that trickles in cannot hold the call open.
        let sent = req
        let (data, resp) = try await runWithinDeadline(deadline) { [session] in try await session.data(for: sent) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        var code = "http_\(status)", message = "", reason = ""
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            code = (o["error"] as? String) ?? code
            message = (o["message"] as? String) ?? ""
            reason = (o["reason"] as? String) ?? ""
        }
        throw APIError(status: status, code: code, message: message, reason: reason)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(status: 0, code: "bad_response", message: "unexpected response")
        }
        return o
    }

    func surveys(lang: String) async throws -> SurveysResponse {
        let data = try await request("GET", "surveys", query: [URLQueryItem(name: "lang", value: lang)])
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(SurveysResponse.self, from: data)
    }

    func createAttempt(offerId: String, token: String, lang: String) async throws -> [String: Any] {
        try object(await request("POST", "attempts", body: ["offer_id": offerId, "token": token, "lang": lang]))
    }

    /// Guests: the install id in, a short-lived guest session token out. 403 `guests_not_allowed` when the app has guests off.
    /// `attest` is the device attestation (or why there is none), sent only when the app asked for it (see `Attestor`).
    /// 403 `attestation_required` / `attestation_failed` when the app enforces attestation and it is missing / invalid.
    func guestSession(installId: String, attest: AttestEvidence? = nil) async throws -> String {
        var body: [String: Any] = ["install_id": installId]
        if let attest { body["attest"] = attest.json }
        let o = try object(await request("POST", "guest/session", body: body))
        guard let s = o["guest_session"] as? String else { throw APIError(status: 0, code: "bad_response", message: "no session") }
        return s
    }

    /// A single-use challenge for an attestation or assertion (key header only, no body).
    func attestChallenge() async throws -> String {
        let o = try object(await request("POST", "attest/challenge"))
        guard let c = o["challenge"] as? String, !c.isEmpty else { throw APIError(status: 0, code: "bad_response", message: "no challenge") }
        return c
    }

    /// Registers an App Attest key for this install. 400 `attest_invalid`, 410 `challenge_expired`.
    func attestRegister(installId: String, keyId: String, attestation: Data, challenge: String) async throws {
        _ = try await request("POST", "attest/ios/register", body: [
            "install_id": installId,
            "key_id": keyId,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge,
        ])
    }

    func createGuestAttempt(offerId: String, guestSession: String, lang: String) async throws -> [String: Any] {
        try object(await request("POST", "attempts", body: ["offer_id": offerId, "guest_session": guestSession, "lang": lang]))
    }

    func putAnswer(code: String, value: Any, attemptToken: String) async throws -> [String: Any] {
        try object(await request("PUT", "attempt/answers", body: ["code": code, "value": value], attemptToken: attemptToken))
    }

    func consent(attemptToken: String) async throws {
        _ = try await request("POST", "attempt/consent", body: [String: Any](), attemptToken: attemptToken)
    }

    func complete(attemptToken: String) async throws -> [String: Any] {
        try object(await request("POST", "attempt/complete", body: [String: Any](), attemptToken: attemptToken))
    }

    func event(offerId: String, type: String) async {
        _ = try? await request("POST", "events", body: ["offer_id": offerId, "type": type])
    }
}
