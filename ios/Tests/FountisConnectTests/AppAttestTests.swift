import XCTest
@testable import FountisConnect

/// Guest device attestation against a fake `DCAppAttestService` (App Attest does not run on the simulator) and a fake
/// API. The expected hashes are fixed SHA-256 digests worked out outside the SDK, so a change in what gets hashed
/// shows up here. Time limits are fractions of a second; production uses `attestTimeout` (10 s).
final class AppAttestTests: XCTestCase {
    private let installId = "install-id"
    // printf 'c1' | shasum -a 256, and the same for 'c2|install-id', 'c3|install-id'
    private let hashC1 = "d0f631ca1ddba8db3bcfcb9e057cdc98d0379f1bee00e75a545147a27dadd982"
    private let hashC2Install = "030d6b0dcd1453f6c75d4e2182542b251a096ddd72a92e746bc012e7e875f38c"
    private let hashC3Install = "aa3f32f744d5877015820f425e78d00fd067f7339691dd7b214cdf1f4eb3d277"

    private var service: FakeAppAttest!
    private var keys: MemoryKeyStore!
    private var api: FakeGuestAPI!

    override func setUp() {
        super.setUp()
        service = FakeAppAttest()
        keys = MemoryKeyStore()
        api = FakeGuestAPI()
        CaptureNetwork.reset()
    }

    private func maker(budget: TimeInterval = 5, cooldown: TimeInterval = 300) -> GuestSessionMaker {
        GuestSessionMaker(attestor: Attestor(service: service, keys: keys, failureCooldown: cooldown), attestBudget: budget)
    }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func unknownKey() -> APIError {
        APIError(status: 400, code: "attest_invalid", message: "the key is not registered", reason: "unknown_key")
    }

    // MARK: discovery

    func testModeParsing() {
        XCTAssertEqual(AttestMode.parse(nil), .off)
        XCTAssertEqual(AttestMode.parse("off"), .off)
        XCTAssertEqual(AttestMode.parse("report"), .report)
        XCTAssertEqual(AttestMode.parse("enforce"), .enforce)
        XCTAssertEqual(AttestMode.parse("strict"), .off, "a mode the SDK does not know never touches attestation")
    }

    func testSurveysDecodesAppAttest() throws {
        func decode(_ app: String) throws -> SurveysResponse {
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            return try dec.decode(SurveysResponse.self, from: Data("{\"app\":\(app),\"surveys\":[]}".utf8))
        }
        let enforce = try decode("{\"public_id\":\"app_1\",\"guests\":true,\"attest\":{\"mode\":\"enforce\",\"android_cloud_project\":\"123456\"}}")
        XCTAssertEqual(enforce.app?.attestMode, .enforce)
        XCTAssertEqual(try decode("{\"guests\":true,\"attest\":{\"mode\":\"report\",\"android_cloud_project\":null}}").app?.attestMode, .report)
        XCTAssertEqual(try decode("{\"guests\":true}").app?.attestMode, .off, "absent means off")
        // A surprise in this block must not break the whole /surveys answer.
        XCTAssertEqual(try decode("{\"guests\":true,\"attest\":{\"mode\":5}}").app?.attestMode, .off)
        XCTAssertEqual(try decode("{\"guests\":true,\"attest\":\"yes\"}").app?.attestMode, .off)
        XCTAssertEqual(try decode("{\"guests\":true,\"attest\":{\"android_cloud_project\":123456}}").app?.attestMode, .off)
    }

    // MARK: modes

    func testModeOffSendsNothing() async throws {
        let token = try await maker().make(api: api, mode: .off, installId: installId)
        XCTAssertEqual(token, "guest-token")
        XCTAssertEqual(api.calls, [.guestSession(installId: installId, attest: nil)], "no challenge, no register, no attest field")
        XCTAssertEqual(service.touched, 0, "attestation is not even asked whether it is supported")
        XCTAssertNil(keys.keyId())
    }

    func testReportModeFirstSessionRegistersTheKeyThenAsserts() async throws {
        _ = try await maker().make(api: api, mode: .report, installId: installId)

        XCTAssertEqual(api.calls, [
            .challenge("c1"),
            .register(installId: installId, keyId: "key-1", attestation: b64("attestation:key-1"), challenge: "c1"),
            .challenge("c2"),
            .guestSession(installId: installId, attest: .assertion(keyId: "key-1", assertion: b64("assertion:key-1"), challenge: "c2")),
        ])
        // Registration signs the challenge alone; the assertion signs challenge + "|" + install id.
        XCTAssertEqual(service.attested.map { $0.keyId }, ["key-1"])
        XCTAssertEqual(service.attested.map { hex($0.hash) }, [hashC1])
        XCTAssertEqual(service.asserted.map { $0.keyId }, ["key-1"])
        XCTAssertEqual(service.asserted.map { hex($0.hash) }, [hashC2Install])
        XCTAssertEqual(keys.keyId(), "key-1", "the key id is kept for the next session")
    }

    func testEnforceModeAttestsTheSameWay() async throws {
        _ = try await maker().make(api: api, mode: .enforce, installId: installId)
        guard case .guestSession(_, let attest)? = api.calls.last, case .assertion? = attest else { return XCTFail("expected an assertion, got \(api.calls)") }
    }

    func testLaterSessionsReuseTheKeyAndOnlyAssert() async throws {
        let m = maker()
        _ = try await m.make(api: api, mode: .report, installId: installId)
        api.reset()
        service.reset()
        _ = try await m.make(api: api, mode: .report, installId: installId)

        XCTAssertEqual(api.calls, [
            .challenge("c1"),
            .guestSession(installId: installId, attest: .assertion(keyId: "key-1", assertion: b64("assertion:key-1"), challenge: "c1")),
        ])
        XCTAssertEqual(service.generated, [], "one key per install")
        XCTAssertEqual(service.attested.count, 0)
    }

    // MARK: could not attest

    func testASimulatorOrOldOSSendsUnavailableUnsupported() async throws {
        service.supported = false
        _ = try await maker().make(api: api, mode: .report, installId: installId)
        XCTAssertEqual(api.calls, [.guestSession(installId: installId, attest: .unavailable("unsupported"))])
        XCTAssertEqual(service.generated, [])
    }

    func testTheSystemSayingFeatureUnsupportedIsUnavailableUnsupported() async throws {
        service.generateKeyError = AppAttestFailure.unsupported
        _ = try await maker().make(api: api, mode: .report, installId: installId)
        XCTAssertEqual(api.calls.last, .guestSession(installId: installId, attest: .unavailable("unsupported")))
    }

    func testAnyOtherFailureIsUnavailableError() async throws {
        service.generateKeyError = AppAttestFailure.failed("server unavailable")
        _ = try await maker().make(api: api, mode: .report, installId: installId)
        XCTAssertEqual(api.calls.last, .guestSession(installId: installId, attest: .unavailable("error")))
    }

    func testASlowAssertionIsUnavailableTimeout() async throws {
        keys.setKeyId("key-1")
        service.assertionBehaviour = .hang
        let started = Date()
        _ = try await maker(budget: 0.3).make(api: api, mode: .report, installId: installId)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the cap is a cap, not a hint")
        XCTAssertEqual(api.calls.last, .guestSession(installId: installId, attest: .unavailable("timeout")))
        XCTAssertEqual(keys.keyId(), "key-1", "a timeout does not forget the key")
    }

    func testASlowRegistrationIsUnavailableTimeoutAndStoresNoKey() async throws {
        service.attestBehaviour = .hang
        _ = try await maker(budget: 0.3).make(api: api, mode: .report, installId: installId)
        XCTAssertEqual(api.calls.last, .guestSession(installId: installId, attest: .unavailable("timeout")))
        XCTAssertNil(keys.keyId(), "a key FOUNTIS never accepted is not kept")
        // Not a refusal, so the next session may try again straight away.
        service.attestBehaviour = .normal
        api.reset()
        _ = try await maker(budget: 5).make(api: api, mode: .report, installId: installId)
        guard case .guestSession(_, let attest)? = api.calls.last, case .assertion? = attest else { return XCTFail("expected an assertion, got \(api.calls)") }
    }

    func testARegistrationFOUNTISRefusesIsUnavailableErrorAndPausesNewKeys() async throws {
        api.registerError = APIError(status: 400, code: "attest_invalid", message: "bad attestation", reason: "bad_signature")
        let m = maker()
        _ = try await m.make(api: api, mode: .report, installId: installId)
        XCTAssertEqual(api.calls.last, .guestSession(installId: installId, attest: .unavailable("error")))
        XCTAssertNil(keys.keyId())
        XCTAssertEqual(service.generated.count, 1)

        // Apple rate-limits attestation: a server that refuses every key must not cost a key per show.
        api.reset()
        _ = try await m.make(api: api, mode: .report, installId: installId)
        XCTAssertEqual(service.generated.count, 1, "no second key during the pause")
        XCTAssertEqual(api.calls, [.guestSession(installId: installId, attest: .unavailable("error"))])
    }

    func testAKeyThisDeviceDoesNotHaveIsReplacedWithoutAServerRoundTrip() async throws {
        keys.setKeyId("ghost-key")
        service.invalidKeys = ["ghost-key"]
        _ = try await maker().make(api: api, mode: .report, installId: installId)
        XCTAssertEqual(api.calls, [
            .challenge("c1"),
            .challenge("c2"),
            .register(installId: installId, keyId: "key-1", attestation: b64("attestation:key-1"), challenge: "c2"),
            .challenge("c3"),
            .guestSession(installId: installId, attest: .assertion(keyId: "key-1", assertion: b64("assertion:key-1"), challenge: "c3")),
        ])
        XCTAssertEqual(keys.keyId(), "key-1")
    }

    // MARK: FOUNTIS no longer knows the key

    func testUnknownKeyRegistersANewKeyOnceAndRetriesTheSessionOnce() async throws {
        keys.setKeyId("old-key")
        api.guestResults = [.failure(unknownKey()), .success("fresh-guest")]
        let token = try await maker().make(api: api, mode: .report, installId: installId)

        XCTAssertEqual(token, "fresh-guest")
        XCTAssertEqual(api.calls, [
            .challenge("c1"),
            .guestSession(installId: installId, attest: .assertion(keyId: "old-key", assertion: b64("assertion:old-key"), challenge: "c1")),
            // the 400 above: new key, registered with a fresh challenge ...
            .challenge("c2"),
            .register(installId: installId, keyId: "key-1", attestation: b64("attestation:key-1"), challenge: "c2"),
            // ... then the session again, with a fresh challenge and an assertion from the new key
            .challenge("c3"),
            .guestSession(installId: installId, attest: .assertion(keyId: "key-1", assertion: b64("assertion:key-1"), challenge: "c3")),
        ])
        XCTAssertEqual(service.asserted.map { hex($0.hash) }.last, hashC3Install)
        XCTAssertEqual(keys.keyId(), "key-1")
    }

    func testUnknownKeyTwiceStopsAfterOneReRegistration() async {
        keys.setKeyId("old-key")
        api.guestResults = [.failure(unknownKey()), .failure(unknownKey())]
        do {
            _ = try await maker().make(api: api, mode: .report, installId: installId)
            XCTFail("expected the second unknown_key to end the call")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "attest_invalid")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(api.guestSessionCalls, 2, "no third try")
        XCTAssertEqual(service.generated.count, 1, "one new key, not one per failure")
    }

    func testOtherAttestInvalidReasonsDoNotReRegister() async {
        keys.setKeyId("old-key")
        api.guestResults = [.failure(APIError(status: 400, code: "attest_invalid", message: "", reason: "bad_signature"))]
        do {
            _ = try await maker().make(api: api, mode: .enforce, installId: installId)
            XCTFail("expected attest_invalid")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "attest_invalid")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(api.guestSessionCalls, 1)
        XCTAssertEqual(service.generated, [])
        XCTAssertEqual(keys.keyId(), "old-key")
    }

    // MARK: 403 means no guest offers

    func testARefusedSessionIsNotRetriedAndMeansNoFill() async {
        for code in ["attestation_required", "attestation_failed"] {
            api.reset()
            api.guestResults = [.failure(APIError(status: 403, code: code, message: "", reason: "nothing_sent"))]
            do {
                _ = try await maker().make(api: api, mode: .enforce, installId: installId)
                XCTFail("expected \(code)")
            } catch let e as APIError {
                XCTAssertEqual(e.code, code)
                XCTAssertTrue(e.isAttestationRefusal)
                // Core ends the check as noFill: the refusal is not an offer to skip, and would repeat for every offer.
                XCTAssertFalse(e.skipsToNextOffer, code)
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(api.guestSessionCalls, 1, "no retry loop for \(code)")
        }
    }

    func testOffersThatOnlyRuleOutThemselvesStillSkipToTheNextOne() {
        for code in ["already_taken", "not_eligible", "closed", "quota_full", "guests_not_allowed"] {
            XCTAssertTrue(APIError(status: 403, code: code, message: "").skipsToNextOffer, code)
        }
        XCTAssertFalse(APIError(status: 500, code: "http_500", message: "").skipsToNextOffer)
        XCTAssertFalse(APIError(status: 400, code: "attest_invalid", message: "", reason: "unknown_key").skipsToNextOffer)
    }

    // MARK: the wire (real ApiClient, stubbed network)

    private func wireClient() -> ApiClient {
        ApiClient(base: URL(string: "https://connect.test/v1")!, key: "pk_test_x", protocolClasses: [CaptureNetwork.self])
    }

    func testChallengeRequestIsAKeyOnlyPostWithNoBody() async throws {
        CaptureNetwork.replies["/v1/attest/challenge"] = (200, "{\"challenge\":\"abc_DEF-123\",\"expires_in\":300}")
        let challenge = try await wireClient().attestChallenge()
        XCTAssertEqual(challenge, "abc_DEF-123")
        let seen = try XCTUnwrap(CaptureNetwork.seen.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.path, "/v1/attest/challenge")
        XCTAssertEqual(seen.key, "pk_test_x")
        XCTAssertTrue(seen.body?.isEmpty ?? true, "empty body")
    }

    func testRegisterBodyMatchesTheProtocol() async throws {
        CaptureNetwork.replies["/v1/attest/ios/register"] = (200, "{\"ok\":true}")
        try await wireClient().attestRegister(installId: "inst", keyId: "a2V5", attestation: Data([0xA1, 0x01, 0xFF]), challenge: "chal")
        let seen = try XCTUnwrap(CaptureNetwork.seen.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.path, "/v1/attest/ios/register")
        XCTAssertEqual(try seen.json() as? [String: String], [
            "install_id": "inst", "key_id": "a2V5", "attestation": Data([0xA1, 0x01, 0xFF]).base64EncodedString(), "challenge": "chal",
        ])
    }

    func testGuestSessionBodyCarriesTheAttestObject() async throws {
        CaptureNetwork.replies["/v1/guest/session"] = (200, "{\"guest_session\":\"gs\",\"expires_in\":3600}")
        let client = wireClient()

        _ = try await client.guestSession(installId: "inst", attest: .assertion(keyId: "a2V5", assertion: "QVNT", challenge: "chal"))
        _ = try await client.guestSession(installId: "inst", attest: .unavailable("timeout"))
        _ = try await client.guestSession(installId: "inst")

        let bodies = try CaptureNetwork.seen.map { try $0.json() as? NSDictionary }
        XCTAssertEqual(bodies[0], ["install_id": "inst", "attest": ["platform": "ios", "key_id": "a2V5", "assertion": "QVNT", "challenge": "chal"]] as NSDictionary)
        XCTAssertEqual(bodies[1], ["install_id": "inst", "attest": ["platform": "ios", "unavailable": "timeout"]] as NSDictionary)
        XCTAssertEqual(bodies[2], ["install_id": "inst"] as NSDictionary, "no attest field when attestation is off")
    }

    func testTheServersRefusalsReachTheSdkWithTheirReason() async {
        CaptureNetwork.replies["/v1/guest/session"] = (403, "{\"error\":\"attestation_required\",\"message\":\"nope\",\"reason\":\"nothing_sent\"}")
        do {
            _ = try await wireClient().guestSession(installId: "inst", attest: nil)
            XCTFail("expected a 403")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 403)
            XCTAssertEqual(e.code, "attestation_required")
            XCTAssertEqual(e.reason, "nothing_sent")
            XCTAssertTrue(e.isAttestationRefusal)
        } catch {
            XCTFail("unexpected \(error)")
        }

        CaptureNetwork.replies["/v1/guest/session"] = (400, "{\"error\":\"attest_invalid\",\"reason\":\"unknown_key\",\"message\":\"unknown key\"}")
        do {
            _ = try await wireClient().guestSession(installId: "inst", attest: nil)
            XCTFail("expected a 400")
        } catch let e as APIError {
            XCTAssertTrue(e.isUnknownAttestKey)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

// MARK: - Fakes

/// A scripted `DCAppAttestService`.
private final class FakeAppAttest: AppAttestService, @unchecked Sendable {
    enum Behaviour { case normal, hang }

    private let lock = NSLock()
    private var _supported = true
    private var _touched = 0
    private var _generated: [String] = []
    private var _attested: [(keyId: String, hash: Data)] = []
    private var _asserted: [(keyId: String, hash: Data)] = []

    var generateKeyError: Error?
    var attestBehaviour = Behaviour.normal
    var assertionBehaviour = Behaviour.normal
    /// Key ids this "device" does not have: asserting with one fails like `DCError.invalidKey`.
    var invalidKeys: Set<String> = []

    var supported: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _supported }
        set { lock.lock(); _supported = newValue; lock.unlock() }
    }
    /// How many times the SDK used the service at all (including asking `isSupported`).
    var touched: Int { lock.lock(); defer { lock.unlock() }; return _touched }
    var generated: [String] { lock.lock(); defer { lock.unlock() }; return _generated }
    var attested: [(keyId: String, hash: Data)] { lock.lock(); defer { lock.unlock() }; return _attested }
    var asserted: [(keyId: String, hash: Data)] { lock.lock(); defer { lock.unlock() }; return _asserted }

    func reset() {
        lock.lock()
        _touched = 0; _generated = []; _attested = []; _asserted = []
        lock.unlock()
    }

    var isSupported: Bool {
        lock.lock(); defer { lock.unlock() }
        _touched += 1
        return _supported
    }

    /// Locking is kept out of the async functions (NSLock is unavailable from async contexts).
    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func generateKey() async throws -> String {
        let id: String = locked {
            _touched += 1
            let id = "key-\(_generated.count + 1)"
            _generated.append(id)
            return id
        }
        if let generateKeyError { throw generateKeyError }
        return id
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        locked { _touched += 1; _attested.append((keyId, clientDataHash)) }
        if attestBehaviour == .hang { try await Task.sleep(nanoseconds: 60_000_000_000) }
        return Data("attestation:\(keyId)".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        locked { _touched += 1; _asserted.append((keyId, clientDataHash)) }
        if invalidKeys.contains(keyId) { throw AppAttestFailure.invalidKey }
        if assertionBehaviour == .hang { try await Task.sleep(nanoseconds: 60_000_000_000) }
        return Data("assertion:\(keyId)".utf8)
    }
}

private final class MemoryKeyStore: AttestKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    func keyId() -> String? { lock.lock(); defer { lock.unlock() }; return id }
    func setKeyId(_ new: String?) { lock.lock(); id = new; lock.unlock() }
}

private enum Call: Equatable {
    case challenge(String)
    case register(installId: String, keyId: String, attestation: String, challenge: String)
    case guestSession(installId: String, attest: AttestEvidence?)
}

/// A scripted API that records every call. Challenges are `c1`, `c2`, ... in call order.
private final class FakeGuestAPI: GuestSessionAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var challenges = 0
    private var _guestResults: [Result<String, Error>] = []
    private var _registerError: Error?

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var guestSessionCalls: Int { calls.filter { if case .guestSession = $0 { return true } else { return false } }.count }
    /// Consumed in order by `guestSession`; when empty it answers `guest-token`.
    var guestResults: [Result<String, Error>] {
        get { lock.lock(); defer { lock.unlock() }; return _guestResults }
        set { lock.lock(); _guestResults = newValue; lock.unlock() }
    }
    var registerError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _registerError }
        set { lock.lock(); _registerError = newValue; lock.unlock() }
    }

    func reset() {
        lock.lock(); _calls = []; challenges = 0; _guestResults = []; lock.unlock()
    }

    /// Locking is kept out of the async functions (NSLock is unavailable from async contexts).
    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func attestChallenge() async throws -> String {
        locked {
            challenges += 1
            let c = "c\(challenges)"
            _calls.append(.challenge(c))
            return c
        }
    }

    func attestRegister(installId: String, keyId: String, attestation: Data, challenge: String) async throws {
        let error: Error? = locked {
            _calls.append(.register(installId: installId, keyId: keyId, attestation: attestation.base64EncodedString(), challenge: challenge))
            return _registerError
        }
        if let error { throw error }
    }

    func guestSession(installId: String, attest: AttestEvidence?) async throws -> String {
        let next: Result<String, Error>? = locked {
            _calls.append(.guestSession(installId: installId, attest: attest))
            return _guestResults.isEmpty ? nil : _guestResults.removeFirst()
        }
        return try (next ?? .success("guest-token")).get()
    }
}

/// A URLProtocol that records the requests an `ApiClient` makes and answers from `replies` (path to status and body).
private final class CaptureNetwork: URLProtocol {
    struct Seen {
        let method: String
        let path: String
        let key: String?
        let body: Data?

        func json() throws -> Any? {
            guard let body, !body.isEmpty else { return nil }
            return try JSONSerialization.jsonObject(with: body)
        }
    }

    private static let lock = NSLock()
    private static var _seen: [Seen] = []
    private static var _replies: [String: (Int, String)] = [:]

    static var seen: [Seen] { lock.lock(); defer { lock.unlock() }; return _seen }
    static var replies: [String: (Int, String)] {
        get { lock.lock(); defer { lock.unlock() }; return _replies }
        set { lock.lock(); _replies = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock(); _seen = []; _replies = [:]; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self._seen.append(Seen(method: request.httpMethod ?? "", path: url.path, key: request.value(forHTTPHeaderField: "X-Fountis-Key"), body: bodyData()))
        let reply = Self._replies[url.path] ?? (404, "{\"error\":\"not_found\"}")
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands an upload's body over as a stream, not as `httpBody`.
    private func bodyData() -> Data? {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
