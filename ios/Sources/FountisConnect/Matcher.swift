import Foundation
import CryptoKit

/// The decoded (never verified) token payload. The server verifies everything on POST /attempts.
struct TokenInfo {
    let sub: String
    let attrs: [String: Any]
    let exp: Double?

    var lang: String? { attrs["lang"] as? String }

    /// Every attribute the token carries, in a fixed order, for the consent screen. FOUNTIS stores all of them when the
    /// study opens, not only the ones the study's conditions use (`requiredAttrs`).
    var carriedAttrs: [String] {
        let order = ["gender", "birth_year", "governorate", "city", "lang"]
        func rank(_ k: String) -> Int { order.firstIndex(of: k) ?? order.count }
        return attrs.filter { !($0.value is NSNull) }.keys.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    var subHash: String {
        let d = SHA256.hash(data: Data(sub.utf8))
        return d.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ token: String) -> TokenInfo? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = o["sub"] as? String, !sub.isEmpty else { return nil }
        return TokenInfo(sub: sub, attrs: (o["attrs"] as? [String: Any]) ?? [:], exp: (o["exp"] as? NSNumber)?.doubleValue)
    }
}

enum Matcher {
    /// Offer is offerable to this person: required attributes present, not expired, every condition holds.
    static func matches(_ offer: Offer, token: TokenInfo, now: Date = Date()) -> Bool {
        if let exp = offer.expiresAt, let d = parseDate(exp), d < now { return false }
        for a in offer.requiredAttrs ?? [] where token.attrs[a] == nil { return false }
        for c in offer.conditions?.all ?? [] where !holds(c, attrs: token.attrs, now: now) { return false }
        return true
    }

    /// Offer is offerable to a guest: the server marked it guest-eligible and it has not expired.
    static func matchesGuest(_ offer: Offer, now: Date = Date()) -> Bool {
        guard offer.guest == true else { return false }
        if let exp = offer.expiresAt, let d = parseDate(exp), d < now { return false }
        return true
    }

    static func attrValue(_ name: String, _ attrs: [String: Any], now: Date) -> Any? {
        if name == "age" {
            guard let by = (attrs["birth_year"] as? NSNumber)?.intValue else { return nil }
            return Calendar(identifier: .gregorian).component(.year, from: now) - by
        }
        return attrs[name]
    }

    static func holds(_ c: Condition, attrs: [String: Any], now: Date) -> Bool {
        guard let v = attrValue(c.attr, attrs, now: now) else { return false }
        let s = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
        let n: Double? = (v as? NSNumber)?.doubleValue ?? Double(s)
        switch c.op {
        case "in", "not_in":
            guard case .array(let list) = c.value else { return false }
            let hit = list.contains { $0.string == s || ($0.number != nil && $0.number == n) }
            return c.op == "in" ? hit : !hit
        case "eq":
            return c.value.string == s || (c.value.number != nil && c.value.number == n)
        case "gte":
            guard let n = n, let t = c.value.number else { return false }
            return n >= t
        case "lte":
            guard let n = n, let t = c.value.number else { return false }
            return n <= t
        case "between":
            guard let n = n, case .array(let r) = c.value, r.count == 2, let lo = r[0].number, let hi = r[1].number else { return false }
            return n >= lo && n <= hi
        default:
            return false
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// `quiet = [start, end]` hours in local time, wrapping midnight (e.g. [22, 9]).
    static func inQuietHours(_ quiet: [Int]?, now: Date = Date()) -> Bool {
        guard let q = quiet, q.count == 2 else { return false }
        let h = Calendar.current.component(.hour, from: now)
        let (s, e) = (q[0], q[1])
        if s == e { return false }
        return s < e ? (h >= s && h < e) : (h >= s || h < e)
    }
}
