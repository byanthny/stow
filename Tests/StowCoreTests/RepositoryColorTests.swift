import XCTest

@testable import StowCore

final class RepositoryColorTests: XCTestCase {
    private func reference(_ owner: String, _ repository: String, _ number: Int = 1) -> PullRequestReference {
        PullRequestReference(owner: owner, repository: repository, number: number)
    }

    func testEachRepositoryKeepsItsColor() {
        let surface = AppearanceSettings.default.colors.surface
        let color = RepositoryColor.hex(for: reference("example", "desktop", 24), onSurface: surface)
        XCTAssertTrue(AppearanceColors.isValidHex(color))
        XCTAssertEqual(RepositoryColor.hex(for: reference("example", "desktop", 27), onSurface: surface), color)
        XCTAssertEqual(RepositoryColor.hex(for: reference("Example", "Desktop", 3), onSurface: surface), color)
    }

    func testRepositoriesSpreadAcrossColors() {
        let surface = AppearanceSettings.default.colors.surface
        let colors = Set(
            (1...24).map { RepositoryColor.hex(for: reference("example", "project-\($0)"), onSurface: surface) })
        XCTAssertEqual(colors.count, RepositoryColor.hues.count)
    }

    func testColorsReadOnAnySurface() throws {
        let presets = [AppearanceSettings.default, .graphite, .paper].map(\.colors.surface)
        let grays = (0...255).map { String(format: "#%02X%02X%02X", $0, $0, $0) }
        let tints = ["#2E3440", "#FDF6E3", "#005F87", "#8A2BE2", "#FFD700", "#B22222"]
        for surface in presets + grays + tints {
            let background = try XCTUnwrap(RGBColor(hex: surface))
            for index in 1...24 {
                let hex = RepositoryColor.hex(for: reference("example", "project-\(index)"), onSurface: surface)
                let contrast = try XCTUnwrap(RGBColor(hex: hex)).contrast(with: background)
                XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(hex) on \(surface)")
            }
        }
    }

    func testAnInvalidSurfaceStillGivesAColor() {
        let color = RepositoryColor.hex(for: reference("example", "desktop"), onSurface: "blue")
        XCTAssertTrue(AppearanceColors.isValidHex(color))
    }

    func testStableHashIsFNV1a() {
        XCTAssertEqual("".stableHash, 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual("a".stableHash, 0xaf63_dc4c_8601_ec8c)
    }
}
