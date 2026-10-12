import XCTest
@testable import FountisConnect

final class MatcherTests: XCTestCase {
    func testConditions() throws {
        let year = Calendar.current.component(.year, from: Date())
        let attrs: [String: Any] = ["gender": "female", "birth_year": year - 33, "city": "erbil"]
        let json = #"{"offer_id":"of_1","conditions":{"all":[{"attr":"gender","op":"in","value":["female"]},{"attr":"age","op":"between","value":[25,44]},{"attr":"city","op":"in","value":["erbil"]}]},"required_attrs":["gender","birth_year"],"reward":{"mode":"free"}}"#
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        let offer = try dec.decode(Offer.self, from: Data(json.utf8))
        let info = TokenInfo(sub: "abc", attrs: attrs, exp: nil)
        XCTAssertTrue(Matcher.matches(offer, token: info))
        XCTAssertFalse(Matcher.matches(offer, token: TokenInfo(sub: "abc", attrs: ["gender": "male", "birth_year": year - 33, "city": "erbil"], exp: nil)))
        XCTAssertTrue(Matcher.inQuietHours([22, 9], now: Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!))
        XCTAssertFalse(Matcher.inQuietHours([22, 9], now: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!))
    }

    /// The consent screen lists everything the token carries, not only what the study's conditions use.
    func testCarriedAttrsListsEveryAttributeInVocabularyOrder() {
        let info = TokenInfo(sub: "abc", attrs: ["lang": "ku", "city": "erbil", "gender": "female", "birth_year": 1991, "governorate": "erbil"], exp: nil)
        XCTAssertEqual(info.carriedAttrs, ["gender", "birth_year", "governorate", "city", "lang"])
        XCTAssertEqual(TokenInfo(sub: "abc", attrs: ["city": "erbil", "gender": NSNull()], exp: nil).carriedAttrs, ["city"])
        XCTAssertEqual(TokenInfo(sub: "abc", attrs: [:], exp: nil).carriedAttrs, [])
    }
}
