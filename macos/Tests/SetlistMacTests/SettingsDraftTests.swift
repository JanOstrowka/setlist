import Foundation
import XCTest
@testable import SetlistMac

final class SettingsDraftTests: XCTestCase {
    func testLoadsDefaultsForMissingKeys() {
        let draft = SettingsDraft(from: EnvFile())

        XCTAssertEqual(draft.openAIKey, "")
        XCTAssertEqual(draft.outputDirectory, "~/Music/YouTube Sets")
        XCTAssertEqual(draft.defaultFormat, "alac")
        XCTAssertFalse(draft.isDirty)
    }

    func testTracksDirtyStateAcrossSave() {
        var draft = SettingsDraft(from: EnvFile(contents: "OPENAI_API_KEY=\n"))

        draft.openAIKey = "sk-new"
        XCTAssertTrue(draft.isDirty)

        draft.markSaved()
        XCTAssertFalse(draft.isDirty)
    }

    func testApplyWritesOnlyManagedKeysAndNormalizes() {
        var file = EnvFile(contents: """
        # header
        OPENAI_API_KEY=
        PORT=9000
        """)
        var draft = SettingsDraft(from: file)
        draft.openAIKey = "  sk-trimmed  "
        draft.openAIModel = ""
        draft.outputDirectory = ""
        draft.defaultFormat = "aac256"

        draft.apply(to: &file)

        XCTAssertEqual(file.value(for: "OPENAI_API_KEY"), "sk-trimmed")
        XCTAssertEqual(file.value(for: "OPENAI_MODEL"), "gpt-4o-mini")
        XCTAssertEqual(file.value(for: "OUTPUT_DIR"), "~/Music/YouTube Sets")
        XCTAssertEqual(file.value(for: "DEFAULT_FORMAT"), "aac256")
        XCTAssertEqual(file.value(for: "PORT"), "9000", "Unmanaged keys stay put")
        XCTAssertTrue(file.contents.hasPrefix("# header\n"))
    }

    func testUnknownFormatFallsBackToALAC() {
        let draft = SettingsDraft(from: EnvFile(contents: "DEFAULT_FORMAT=mp3\n"))

        XCTAssertEqual(draft.defaultFormat, "alac")
    }

    func testAbbreviatesHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(
            SettingsDraft.abbreviatingHome(home + "/Music/Sets"),
            "~/Music/Sets"
        )
        XCTAssertEqual(SettingsDraft.abbreviatingHome(home), "~")
        XCTAssertEqual(
            SettingsDraft.abbreviatingHome("/Volumes/External/Sets"),
            "/Volumes/External/Sets"
        )
    }
}
