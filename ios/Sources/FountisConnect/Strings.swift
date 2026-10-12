import Foundation

/// Reads the shared i18n JSON (the same files the engine uses) for the few host-side strings.
enum Strings {
    private static var cache: [String: [String: String]] = [:]

    private static func table(_ lang: String) -> [String: String] {
        if let t = cache[lang] { return t }
        var t: [String: String] = [:]
        if let url = Bundle.module.url(forResource: lang, withExtension: "json", subdirectory: "Engine/i18n"),
           let d = try? Data(contentsOf: url),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] { t = o }
        cache[lang] = t
        return t
    }

    static func get(_ key: String, lang: String, _ vars: [String: String] = [:]) -> String {
        var s = table(lang)[key] ?? table("en")[key] ?? key
        for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    static func normalize(_ lang: String?) -> String {
        guard let l = lang?.lowercased() else { return "en" }
        let two = l.hasPrefix("kmr") ? "kmr" : l.hasPrefix("ckb") ? "ku" : String(l.prefix(2))
        return ["en", "ku", "kmr", "ar"].contains(two) ? two : "en"
    }

    static func isRTL(_ lang: String) -> Bool { ["ku", "kmr", "ar"].contains(lang) }

    static var deviceLang: String {
        normalize(Locale.preferredLanguages.first)
    }
}
