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
