import CryptoKit
import DeviceCheck
import Foundation

// Device attestation for guests (App Attest). Only `POST /v1/guest/session` carries it; people signed in with a partner
// token are vouched for by that token and never touch any of this. Nothing here is ever shown to the person.
//
// Wire format: the shared protocol, section "iOS (DCAppAttestService)". In short:
//   key registration, once per install:  challenge -> generateKey -> attestKey(SHA256(challenge)) -> /attest/ios/register
//   per guest session:                   challenge -> generateAssertion(SHA256(challenge + "|" + install_id)) -> /guest/session

/// How long all attestation steps of one guest session may take together (challenges, key registration, assertion).
/// Past it the SDK sends `unavailable: "timeout"` and carries on. Same 10 seconds as the Android SDK.
let attestTimeout: TimeInterval = 10

/// `app.attest.mode` from `/surveys`. Anything the SDK does not know reads as `off`.
enum AttestMode: Equatable, Sendable {
    /// Never touch attestation: no challenge, no key, no `attest` field.
    case off
    /// Attest; FOUNTIS records the outcome and always grants the guest session.
    case report
    /// Attest; FOUNTIS grants the guest session only for a valid attestation (403 otherwise).
    case enforce

    static func parse(_ raw: String?) -> AttestMode {
        switch raw {
        case "report": return .report
        case "enforce": return .enforce
        default: return .off
        }
    }
}

/// The `attest` object of the guest session body: an assertion, or the reason there is none.
enum AttestEvidence: Equatable, Sendable {
    case assertion(keyId: String, assertion: String, challenge: String)
    /// `unsupported` (simulator, old OS), `timeout`, `error`.
    case unavailable(String)

    var json: [String: Any] {
        switch self {
        case let .assertion(keyId, assertion, challenge):
            return ["platform": "ios", "key_id": keyId, "assertion": assertion, "challenge": challenge]
        case .unavailable(let code):
            return ["platform": "ios", "unavailable": code]
        }
    }
}

// MARK: - The system service, behind a protocol

/// Why App Attest failed, in the few ways that change what the SDK does.
enum AppAttestFailure: Error, Equatable {
    /// This device or OS cannot do App Attest.
    case unsupported
    /// This device does not know the key (a backup restore or OS reset kept our copy of its id, not the key).
    case invalidKey
    case failed(String)
}

/// The part of `DCAppAttestService` the SDK uses, so tests can fake it (App Attest does not run on the simulator).
/// Implementations throw `AppAttestFailure` for the failures above, anything else for the rest.
protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

struct SystemAppAttestService: AppAttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        do { return try await DCAppAttestService.shared.generateKey() } catch { throw Self.translate(error) }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        do { return try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) } catch { throw Self.translate(error) }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        do { return try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) } catch { throw Self.translate(error) }
    }

    static func translate(_ error: Error) -> Error {
        guard let e = error as? DCError else { return error }
        switch e.code {
        case .featureUnsupported: return AppAttestFailure.unsupported
        case .invalidKey: return AppAttestFailure.invalidKey
        default: return AppAttestFailure.failed("DCError \(e.errorCode)")
        }
    }
}

// MARK: - Key storage

/// Where the App Attest key id lives: once per install, next to the guest install id.
protocol AttestKeyStore: Sendable {
    func keyId() -> String?
    func setKeyId(_ id: String?)
}

struct UserDefaultsAttestKeyStore: AttestKeyStore {
    private static let key = "guest.attest_key_id"
    private var defaults: UserDefaults { UserDefaults(suiteName: "org.fountis.connect.state") ?? .standard }

    func keyId() -> String? {
        guard let v = defaults.string(forKey: Self.key), !v.isEmpty else { return nil }
        return v
    }

    func setKeyId(_ id: String?) {
        if let id { defaults.set(id, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }
}

// MARK: - API surface

/// The two attestation calls the `Attestor` needs from the API.
protocol AttestAPI: Sendable {
    func attestChallenge() async throws -> String
    func attestRegister(installId: String, keyId: String, attestation: Data, challenge: String) async throws
}

protocol GuestSessionAPI: AttestAPI {
    func guestSession(installId: String, attest: AttestEvidence?) async throws -> String
}

extension ApiClient: GuestSessionAPI {}

extension APIError {
    /// 403 from `/guest/session` on an app that enforces attestation: nothing sent (`attestation_required`) or sent and
    /// invalid (`attestation_failed`). The SDK offers no guest studies this time and does not retry.
    var isAttestationRefusal: Bool { code == "attestation_required" || code == "attestation_failed" }

    /// 400 `attest_invalid` because FOUNTIS no longer knows the key: register a new one, once.
    var isUnknownAttestKey: Bool {
        code == "attest_invalid" && (reason == "unknown_key" || message.contains("unknown_key"))
    }

    /// A failed attempt that only rules out this offer: the check moves on to the next one. Any other failure ends the
    /// check as `noFill`, attestation refusals included (they would repeat for every offer).
    var skipsToNextOffer: Bool {
        !isAttestationRefusal && ["already_taken", "not_eligible", "closed", "quota_full", "guests_not_allowed"].contains(code)
    }
}

// MARK: - Attestor

/// Makes the attestation for a guest session: registers an App Attest key once per install, then answers each guest
/// session with an assertion. `evidence` never throws except for cancellation; whatever goes wrong becomes
/// `.unavailable(code)` and the guest session request goes on without an attestation (FOUNTIS decides what that means).
actor Attestor {
    private let service: AppAttestService
    private let keys: AttestKeyStore
    private let failureCooldown: TimeInterval
    private var registrationPausedUntil: Date?

    /// `failureCooldown`: after a key registration that Apple or FOUNTIS turned down, no new key is made for this long
    /// (Apple rate-limits attestation, and a server that rejects every key would otherwise cost one per show).
    init(service: AppAttestService = SystemAppAttestService(), keys: AttestKeyStore = UserDefaultsAttestKeyStore(), failureCooldown: TimeInterval = 300) {
        self.service = service
        self.keys = keys
        self.failureCooldown = failureCooldown
    }

    /// Everything shares `timeout` seconds. Past it: `.unavailable("timeout")`.
    func evidence(api: AttestAPI, installId: String, timeout: TimeInterval = attestTimeout) async throws -> AttestEvidence {
        guard service.isSupported else { return .unavailable("unsupported") }
        do {
            return try await runWithinDeadline(timeout) { [self] in try await self.produce(api: api, installId: installId) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let code = Self.unavailableCode(for: error)
            fcLog.debug("attestation unavailable (\(code)): \(String(describing: error))")
            return .unavailable(code)
        }
    }

    /// FOUNTIS no longer knows this key: forget it so the next `evidence` registers a new one.
    func forget(keyId: String) {
        if keys.keyId() == keyId { keys.setKeyId(nil) }
    }

    static func unavailableCode(for error: Error) -> String {
        if let u = error as? URLError, u.code == .timedOut { return "timeout" }
        if let f = error as? AppAttestFailure, f == .unsupported { return "unsupported" }
        return "error"
    }

    // MARK: steps

    private func produce(api: AttestAPI, installId: String) async throws -> AttestEvidence {
        var keyId = try await keyIdRegisteringIfNeeded(api: api, installId: installId)
        do {
            return try await assertion(keyId: keyId, api: api, installId: installId)
        } catch AppAttestFailure.invalidKey {
            // The device does not have the key our storage names (restored backup, OS reset): make a new one, once.
            fcLog.debug("attest key unknown to this device; registering a new one")
            keys.setKeyId(nil)
            keyId = try await register(api: api, installId: installId)
            return try await assertion(keyId: keyId, api: api, installId: installId)
        }
    }

    private func keyIdRegisteringIfNeeded(api: AttestAPI, installId: String) async throws -> String {
        if let k = keys.keyId() { return k }
        return try await register(api: api, installId: installId)
    }

    /// Steps 1 to 3 of the protocol. The key id is stored only once FOUNTIS accepted it.
    private func register(api: AttestAPI, installId: String) async throws -> String {
        if let until = registrationPausedUntil, until > Date() {
            throw AppAttestFailure.failed("key registration paused after an earlier failure")
        }
        var madeKey = false
        do {
            let challenge = try await api.attestChallenge()
            let keyId = try await service.generateKey()
            madeKey = true
            let attestation = try await service.attestKey(keyId, clientDataHash: AttestHash.of(challenge))
            try await api.attestRegister(installId: installId, keyId: keyId, attestation: attestation, challenge: challenge)
            keys.setKeyId(keyId)
            registrationPausedUntil = nil
            return keyId
        } catch {
            // A timeout or cancellation says nothing about the key; a refusal after the key existed does.
            if madeKey, !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .timedOut {
                registrationPausedUntil = Date().addingTimeInterval(failureCooldown)
            }
            throw error
        }
    }

    /// Steps 4 and 5 of the protocol.
    private func assertion(keyId: String, api: AttestAPI, installId: String) async throws -> AttestEvidence {
        let challenge = try await api.attestChallenge()
        let data = try await service.generateAssertion(keyId, clientDataHash: AttestHash.of(challenge + "|" + installId))
        return .assertion(keyId: keyId, assertion: data.base64EncodedString(), challenge: challenge)
    }
}

enum AttestHash {
    /// SHA-256 of the UTF-8 bytes: the `clientDataHash` App Attest takes.
    static func of(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }
}

// MARK: - Guest session with attestation

/// Opens a guest session the way the protocol says: no attestation when the mode is `off`, otherwise evidence first,
/// and one re-registration when FOUNTIS answers `attest_invalid` for a key it does not know.
struct GuestSessionMaker: Sendable {
    let attestor: Attestor
    /// Shared by the attestation steps of one call, re-registration included.
    var attestBudget: TimeInterval = attestTimeout

    /// Throws `APIError` as the guest session call does; `attestation_required` / `attestation_failed` (403) are not retried.
    func make(api: GuestSessionAPI, mode: AttestMode, installId: String) async throws -> String {
        guard mode != .off else { return try await api.guestSession(installId: installId, attest: nil) }
        let started = Date()
        var reRegistered = false
        while true {
            let remaining = max(attestBudget - Date().timeIntervalSince(started), 0)
            let evidence = try await attestor.evidence(api: api, installId: installId, timeout: remaining)
            do {
                return try await api.guestSession(installId: installId, attest: evidence)
            } catch let e as APIError where !reRegistered && e.isUnknownAttestKey {
                guard case .assertion(let keyId, _, _) = evidence else { throw e }
                reRegistered = true
                fcLog.debug("attest key unknown to FOUNTIS; registering a new one")
                await attestor.forget(keyId: keyId)
            }
        }
    }
}
