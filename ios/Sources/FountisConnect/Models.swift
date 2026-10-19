import Foundation
import os

let fcLog = Logger(subsystem: "org.fountis.connect", category: "sdk")

/// What `show()` returns. Every failure is `.noFill`.
public enum FountisResult: Equatable, Sendable {
    /// Nothing to show (no matching study, no consent, no token, network trouble, nowhere to present).
    case noFill
    /// The person closed the study before finishing it, or was screened out / the study filled up.
    case dismissed
    /// The person finished the study.
    case completed
}

/// Anonymous lifecycle event for the host app (`onEvent`). Carries no titles, topics or answers.
public struct FountisEvent: Sendable {
    /// `shown`, `dismissed`, `completed`, `noFill`, `notified`
    public let type: String
    public let offerId: String?
}

/// Minimal Codable JSON value (for portable conditions and pass-through).
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}

struct Condition: Codable {
    let attr: String
    let op: String
    let value: JSONValue
}

struct Conditions: Codable {
    let all: [Condition]?
}

struct OfferReward: Codable {
    let mode: String
    let units: Int?
    let unitName: JSONValue?

    var isRewarded: Bool { mode == "rewarded" && (units ?? 0) > 0 }

    func unitLabel(lang: String) -> String {
        switch unitName {
        case .string(let s)?: return s
        case .object(let o)?: return o[lang]?.string ?? o["en"]?.string ?? o.values.compactMap { $0.string }.first ?? ""
        default: return ""
        }
    }
}

struct Offer: Codable {
    let offerId: String
    let conditions: Conditions?
    let requiredAttrs: [String]?
    let loiMinutes: Int?
    let reward: OfferReward?
    let locales: [String]?
    let expiresAt: String?
    /// Open to guests (people with no signed token). Only ever true on apps FOUNTIS allowed guests in.
    let guest: Bool?
}

struct SurveysConfig: Codable {
    let maxNotificationsPerDay: Int?
    let quietHours: [Int]?
    let checkIntervalMinutes: Int?
}

struct SurveysAppInfo: Codable {
    let publicId: String?
    let env: String?
    let name: String?
    /// The app may offer free studies to guests.
    let guests: Bool?
    /// Device attestation for guests (`off` when absent).
    let attest: SurveysAttestInfo?

    var attestMode: AttestMode { AttestMode.parse(attest?.mode) }
}

/// `app.attest` from `/surveys`. Decoding never throws: a field of the wrong type reads as absent (so as `off`), because
/// a surprise here must not turn every check into `noFill`. Only `mode` matters on iOS (`android_cloud_project` is Android's).
struct SurveysAttestInfo: Codable {
    let mode: String?

    private enum CodingKeys: String, CodingKey { case mode }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        mode = try? c?.decodeIfPresent(String.self, forKey: .mode)
    }
}

struct SurveysResponse: Codable {
    let app: SurveysAppInfo?
    let config: SurveysConfig?
    let surveys: [Offer]
}
