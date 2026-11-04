import Foundation
import XCTest

@testable import StowCore

final class ProfileTests: XCTestCase {
    func testSanitizedNameRemovesControlAndBidirectionalCharacters() {
        XCTAssertEqual(ProfileIdentity.sanitizedName("Wo\u{202E}rk\n"), "Work")
        XCTAssertEqual(ProfileIdentity.sanitizedName("\u{2066}Acme\u{2069}"), "Acme")
        XCTAssertNil(ProfileIdentity.sanitizedName(" \u{200E} "))
        XCTAssertNil(ProfileIdentity.sanitizedName("   "))
        XCTAssertEqual(ProfileIdentity.sanitizedName("  A\u{2028}B\u{2029}C\u{061C}D  "), "ABCD")
    }

    func testSanitizedNameRemovesInvisibleCharacters() {
        XCTAssertEqual(ProfileIdentity.sanitizedName("Work\u{200B}"), "Work")
        XCTAssertEqual(ProfileIdentity.sanitizedName("W\u{00AD}o\u{180E}r\u{2060}k\u{FEFF}"), "Work")
        XCTAssertNil(ProfileIdentity.sanitizedName("\u{200B}\u{FEFF}"))
    }

    func testSanitizedNameKeepsEmojiAndRightToLeftText() {
        XCTAssertEqual(ProfileIdentity.sanitizedName("👨‍👩‍👧 Family"), "👨‍👩‍👧 Family")
        XCTAssertEqual(ProfileIdentity.sanitizedName("עבודה"), "עבודה")
        XCTAssertEqual(ProfileIdentity.sanitizedName("a\u{200C}b\u{200D}c"), "a\u{200C}b\u{200D}c")
        XCTAssertEqual(ProfileIdentity.sanitizedName(String(repeating: "a", count: 200))?.count, 80)
        let family = String(repeating: "👨‍👩‍👧", count: 100)
        XCTAssertEqual(ProfileIdentity.sanitizedName(family)?.count, 80)
    }

    func testColorValidation() {
        XCTAssertTrue(ProfileIdentity.isValidColor("#1A2B3C"))
        XCTAssertTrue(ProfileIdentity.isValidColor("#1a2b3c"))
        for bad in ["1A2B3C", "#12345", "#GGGGGG", "#1A2B3C4D", "", "#１２３４５６"] {
            XCTAssertFalse(ProfileIdentity.isValidColor(bad), bad)
        }
    }

    private func identityData(id: UUID, name: String = "Work", color: String = "#1A2B3C") throws -> Data {
        try JSONEncoder().encode(ProfileIdentity(id: id, name: name, color: color))
    }

    func testIdentityDecodesAndSanitizesName() throws {
        let id = UUID()
        let data = try identityData(id: id, name: "  Wo\u{202E}rk\n")
        let decoded = try ProfileIdentity.decode(data, folderID: id)
        XCTAssertEqual(decoded, ProfileIdentity(id: id, name: "Work", color: "#1A2B3C"))
        XCTAssertEqual(try ProfileIdentity.decode(data, folderID: nil).id, id)
    }

    func testIdentityRejectsMismatchedFolderAndOversizedData() throws {
        let id = UUID()
        let data = try identityData(id: id)
        XCTAssertThrowsError(try ProfileIdentity.decode(data, folderID: UUID())) {
            XCTAssertEqual($0 as? ProfileError, .invalidIdentity)
        }
        let padded = data + Data(repeating: 0x20, count: ProfileIdentity.maximumBytes + 1 - data.count)
        XCTAssertEqual(padded.count, ProfileIdentity.maximumBytes + 1)
        XCTAssertThrowsError(try ProfileIdentity.decode(padded, folderID: id)) {
            XCTAssertEqual($0 as? ProfileError, .invalidIdentity)
        }
        let atLimit = data + Data(repeating: 0x20, count: ProfileIdentity.maximumBytes - data.count)
        XCTAssertEqual(try ProfileIdentity.decode(atLimit, folderID: id).id, id)
        XCTAssertThrowsError(try ProfileIdentity.decode(identityData(id: id, color: "red"), folderID: id)) {
            XCTAssertEqual($0 as? ProfileError, .invalidIdentity)
        }
        XCTAssertThrowsError(try ProfileIdentity.decode(identityData(id: id, name: " \u{200E} "), folderID: id)) {
            XCTAssertEqual($0 as? ProfileError, .invalidIdentity)
        }
        XCTAssertThrowsError(try ProfileIdentity.decode(Data("{".utf8), folderID: id)) {
            XCTAssertEqual($0 as? ProfileError, .invalidIdentity)
        }
    }

    func testIconValidation() {
        let valid: [ProfileIcon] = [
            .symbol("star.fill"), .symbol("1.circle"), .emoji("😀"), .emoji("👨‍👩‍👧"), .emoji("🇺🇸"),
            // A keycap or a text-style emoji counts once it asks for emoji presentation with U+FE0F.
            .emoji("1\u{FE0F}\u{20E3}"), .emoji("\u{00A9}\u{FE0F}"), .emoji("\u{263A}\u{FE0F}"),
        ]
        for icon in valid { XCTAssertEqual(ProfileIcon.validated(icon), icon, "\(icon)") }
        // Digits, #, *, and © are emoji only as keycap bases or with U+FE0F; alone they are text.
        for text in ["1", "#", "*", "\u{00A9}", "\u{263A}", "a\u{FE0F}", "\u{FE0F}"] {
            let scalars = text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
            XCTAssertNil(ProfileIcon.validated(.emoji(text)), scalars)
        }
        let longest = String(repeating: "a", count: 64)
        XCTAssertEqual(ProfileIcon.validated(.symbol(longest)), .symbol(longest))
        // One character of 32 UTF-8 bytes: a 4-byte emoji with fourteen 2-byte combining marks.
        let largest = "😀" + String(repeating: "\u{0301}", count: 14)
        XCTAssertEqual(largest.count, 1)
        XCTAssertEqual(largest.utf8.count, 32)
        XCTAssertEqual(ProfileIcon.validated(.emoji(largest)), .emoji(largest))
        let invalid: [ProfileIcon] = [
            .symbol("star fill"), .symbol(""), .symbol(String(repeating: "a", count: 65)), .symbol("star/fill"),
            .symbol("ſtar"), .emoji("😀😀"), .emoji("a"), .emoji(""), .emoji(" 😀"), .emoji(largest + "\u{0301}"),
        ]
        for icon in invalid { XCTAssertNil(ProfileIcon.validated(icon), "\(icon)") }
    }

    func testIdentityRoundTripsItsIcon() throws {
        let id = UUID()
        for icon in [ProfileIcon.symbol("star.fill"), .emoji("😀"), nil] {
            let identity = ProfileIdentity(id: id, name: "Work", color: "#1A2B3C", icon: icon)
            XCTAssertEqual(try ProfileIdentity.decode(JSONEncoder().encode(identity), folderID: id), identity)
        }
        let smiling = ProfileIdentity(id: id, name: "Work", color: "#1A2B3C", icon: .emoji("😀"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(smiling)) as? [String: Any])
        XCTAssertEqual(object["icon"] as? [String: String], ["emoji": "😀"])
        let bare = try JSONEncoder().encode(ProfileIdentity(id: id, name: "Work", color: "#1A2B3C"))
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: bare) as? [String: Any])["icon"])
    }

    func testInvalidIconDecodesAsNil() throws {
        let id = UUID()
        let icons = [
            #"{"symbol":"star fill"}"#, #"{"symbol":""}"#, #"{"emoji":"😀😀"}"#, #"{"emoji":"a"}"#, #"{"symbol":5}"#,
            #""star.fill""#, #"{"symbol":"star.fill","emoji":"😀"}"#, #"{"badge":"star.fill"}"#, "{}", "null", "[]",
        ]
        for icon in icons {
            let json = ##"{"id":"\##(id.uuidString)","name":"Work","color":"#1A2B3C","icon":\##(icon)}"##
            let decoded = try ProfileIdentity.decode(Data(json.utf8), folderID: id)
            XCTAssertEqual(decoded, ProfileIdentity(id: id, name: "Work", color: "#1A2B3C"), icon)
        }
    }

    func testIndexRoundTripsAndFillsMissingOptionalFields() throws {
        let a = UUID(), b = UUID()
        var index = ProfileIndex()
        index.order = [a, b]
        index.open = [.init(id: a, isHidden: false), .init(id: b, isHidden: true)]
        index.lastActiveID = a
        index.seenIDs = [a, b]
        index.alwaysShowProfileName = true
        XCTAssertEqual(try ProfileIndex.decode(JSONEncoder().encode(index)), index)
        XCTAssertEqual(try ProfileIndex.decode(Data(#"{"schemaVersion":1}"#.utf8)), ProfileIndex())
    }

    func testIndexRejectsNewerVersionAndOversizedData() throws {
        XCTAssertThrowsError(try ProfileIndex.decode(Data(#"{"schemaVersion":2,"order":"future shape"}"#.utf8))) {
            XCTAssertEqual($0 as? ProfileError, .newerIndex(2))
        }
        let json = Data(#"{"schemaVersion":1}"#.utf8)
        let padded = json + Data(repeating: 0x20, count: ProfileIndex.maximumBytes + 1 - json.count)
        XCTAssertThrowsError(try ProfileIndex.decode(padded)) {
            XCTAssertEqual($0 as? ProfileError, .invalidIndex)
        }
        for bad in ["not json", "{}", #"{"schemaVersion":0}"#, #"{"schemaVersion":1,"order":["x"]}"#] {
            XCTAssertThrowsError(try ProfileIndex.decode(Data(bad.utf8)), bad) {
                XCTAssertEqual($0 as? ProfileError, .invalidIndex)
            }
        }
    }
}
