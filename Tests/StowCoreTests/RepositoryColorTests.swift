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

    func testEachRepositoryAndSurfaceIsWorkedOutOnce() {
        let surface = "#123456"
        let key = RepositoryColor.Key(repository: "example/memo", surface: surface)
        let color = RepositoryColor.hex(for: reference("Example", "Memo"), onSurface: surface)
        XCTAssertEqual(RepositoryColor.chosen.cached(key), color, "The color was not kept")
        XCTAssertEqual(RepositoryColor.hex(for: reference("example", "memo", 9), onSurface: surface), color)
        XCTAssertNil(RepositoryColor.chosen.cached(.init(repository: "example/memo", surface: "#654321")))
    }

    func testKeptColorsStayFewAndAgreeAcrossThreads() {
        let surfaces = ["#101010", "#F0F0F0", "#2E3440"]
        let expected = (0..<300).map {
            RepositoryColor.hex(for: reference("example", "spread-\($0)"), onSurface: "#101010")
        }
        XCTAssertLessThanOrEqual(RepositoryColor.chosen.count, 256)
        let mismatches = ColorMismatches()
        DispatchQueue.concurrentPerform(iterations: 900) { index in
            let color = RepositoryColor.hex(
                for: reference("example", "spread-\(index % 300)"), onSurface: surfaces[index % surfaces.count])
            if surfaces[index % surfaces.count] == "#101010", color != expected[index % 300] { mismatches.add(color) }
        }
        XCTAssertEqual(mismatches.colors, [])
        XCTAssertLessThanOrEqual(RepositoryColor.chosen.count, 256)
    }

    func testStableHashIsFNV1a() {
        XCTAssertEqual("".stableHash, 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual("a".stableHash, 0xaf63_dc4c_8601_ec8c)
    }
}

/// Colors that differed from the expected ones, gathered from many threads.
private final class ColorMismatches: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String] = []
    var colors: [String] { lock.withLock { found } }
    func add(_ color: String) { lock.withLock { found.append(color) } }
}
