import Foundation
import XCTest
@testable import SetlistMac

final class EnvFileTests: XCTestCase {
    func testParsesCommentsQuotesAndExports() {
        let file = EnvFile(contents: """
        # comment
        PLAIN=value
        SPACED = "~/Music/YouTube Sets"
        SINGLE='it''s'
        export EXPORTED=yes
        INLINE=abc # trailing comment
        ESCAPED="say \\"hi\\" \\\\ back"
        EMPTY=
        =nokey
        NOEQUALS
        """)

        XCTAssertEqual(file.value(for: "PLAIN"), "value")
        XCTAssertEqual(file.value(for: "SPACED"), "~/Music/YouTube Sets")
        XCTAssertEqual(file.value(for: "SINGLE"), "it")
        XCTAssertEqual(file.value(for: "EXPORTED"), "yes")
        XCTAssertEqual(file.value(for: "INLINE"), "abc")
        XCTAssertEqual(file.value(for: "ESCAPED"), "say \"hi\" \\ back")
        XCTAssertEqual(file.value(for: "EMPTY"), "")
        XCTAssertNil(file.value(for: "MISSING"))
        XCTAssertNil(file.value(for: ""))
    }

    func testLastAssignmentWins() {
        let file = EnvFile(contents: "PORT=1\nPORT=2\n")

        XCTAssertEqual(file.value(for: "PORT"), "2")
    }

    func testSetReplacesInPlaceAndKeepsOtherLines() {
        var file = EnvFile(contents: """
        # Keep me
        OPENAI_API_KEY=
        OUTPUT_DIR="~/Music/YouTube Sets"
        PORT=8765
        """)

        file.set("sk-live", for: "OPENAI_API_KEY")
        file.set("~/Music/Live Sets", for: "OUTPUT_DIR")
        file.set("aac256", for: "DEFAULT_FORMAT")

        XCTAssertEqual(file.contents, """
        # Keep me
        OPENAI_API_KEY=sk-live
        OUTPUT_DIR="~/Music/Live Sets"
        PORT=8765
        DEFAULT_FORMAT=aac256

        """)
    }

    func testSetNilWritesEmptyAssignment() {
        var file = EnvFile(contents: "OPENAI_API_KEY=sk-old\n")

        file.set(nil, for: "OPENAI_API_KEY")

        XCTAssertEqual(file.contents, "OPENAI_API_KEY=\n")
        XCTAssertEqual(file.value(for: "OPENAI_API_KEY"), "")
    }

    func testRenderQuotesOnlyWhenNeeded() {
        XCTAssertEqual(EnvFile.render("plain"), "plain")
        XCTAssertEqual(EnvFile.render(""), "")
        XCTAssertEqual(EnvFile.render("has space"), "\"has space\"")
        XCTAssertEqual(EnvFile.render("a#b"), "\"a#b\"")
        XCTAssertEqual(EnvFile.render("q\"q"), "\"q\\\"q\"")
    }

    func testRoundTripsThroughFileWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.env")

        var file = EnvFile()
        file.set("~/Music/Sets With Spaces", for: "OUTPUT_DIR")
        file.set("sk-\"quoted\"", for: "OPENAI_API_KEY")
        try file.write(to: url)

        let reloaded = EnvFile(contentsOf: url)
        XCTAssertEqual(reloaded, file)
        XCTAssertEqual(reloaded.value(for: "OUTPUT_DIR"), "~/Music/Sets With Spaces")
        XCTAssertEqual(reloaded.value(for: "OPENAI_API_KEY"), "sk-\"quoted\"")

        let permissions = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testLoadingAndSavingDoesNotGrowTheFile() {
        let original = "A=1\nB=2\n"

        let file = EnvFile(contents: original)

        XCTAssertEqual(file.contents, original)
        XCTAssertEqual(EnvFile(contents: file.contents).contents, original)
    }
}
