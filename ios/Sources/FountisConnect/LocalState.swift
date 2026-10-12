import Foundation

/// Per-person local state (offers already notified / dismissed / taken, daily notification count).
/// Lives only in this app's UserDefaults suite, keyed by sha256(sub). Never sent anywhere.
struct LocalStateData: Codable {
    var notified: [String] = []
    var dismissed: [String] = []
    var taken: [String] = []
    var day: String = ""
    var dayCount: Int = 0
}

/// The guest install id: 24 random bytes made on first use and kept in this app's UserDefaults suite.
/// It is not a device identifier and is never derived from one. FOUNTIS stores only a hash of it.
enum GuestInstall {
    private static let key = "guest.install_id"

    static func id() -> String {
        let defaults = UserDefaults(suiteName: "org.fountis.connect.state") ?? .standard
        if let v = defaults.string(forKey: key), v.count >= 22 { return v }
        var bytes = [UInt8](repeating: 0, count: 24)
        let ok = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        if !ok { for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) } }
        let v = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        defaults.set(v, forKey: key)
        return v
    }
}

final class LocalState {
    private let defaults: UserDefaults
    private let key: String

    init(subHash: String) {
        defaults = UserDefaults(suiteName: "org.fountis.connect.state") ?? .standard
        key = "s." + subHash
    }

    private(set) var data: LocalStateData {
        get {
            guard let d = defaults.data(forKey: key), let v = try? JSONDecoder().decode(LocalStateData.self, from: d) else { return LocalStateData() }
            return v
        }
        set { if let d = try? JSONEncoder().encode(newValue) { defaults.set(d, forKey: key) } }
    }

    private static func today() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func add(_ id: String, to path: WritableKeyPath<LocalStateData, [String]>) {
        var v = data
        if !v[keyPath: path].contains(id) { v[keyPath: path].append(id) }
        if v[keyPath: path].count > 200 { v[keyPath: path].removeFirst(v[keyPath: path].count - 200) }
        data = v
    }

    func markNotified(_ id: String) {
        add(id, to: \.notified)
        var v = data
        if v.day != Self.today() { v.day = Self.today(); v.dayCount = 0 }
        v.dayCount += 1
        data = v
    }
    func markDismissed(_ id: String) { add(id, to: \.dismissed) }
    func markTaken(_ id: String) { add(id, to: \.taken) }

    var notificationsToday: Int { data.day == Self.today() ? data.dayCount : 0 }

    /// For the explicit `show()`: only studies already finished are excluded.
    func isTaken(_ id: String) -> Bool { data.taken.contains(id) }
    /// For auto-show and notifications: anything the person has already seen, closed or finished.
    func isHandled(_ id: String) -> Bool { let d = data; return d.taken.contains(id) || d.dismissed.contains(id) || d.notified.contains(id) }
    func isSuppressedForNotification(_ id: String) -> Bool { isHandled(id) }
    func isSuppressedForAutoShow(_ id: String) -> Bool { let d = data; return d.taken.contains(id) || d.dismissed.contains(id) }

    func clear() { defaults.removeObject(forKey: key) }
}
