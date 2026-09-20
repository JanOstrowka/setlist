import Foundation
import XCTest
@testable import SetlistMac

final class SettingsDraftTests: XCTestCase {
    func testLoadsDefaultsForMissingKeys() {
        let draft = SettingsDraft(from: EnvFile())

        XCTAssertEqual(draft.outputDirectory, "~/Music/YouTube Sets")
        XCTAssertEqual(draft.defaultFormat, "alac")
        XCTAssertFalse(draft.isDirty)
    }

    func testTracksDirtyStateAcrossSave() {
        var draft = SettingsDraft(from: EnvFile(contents: "DEFAULT_FORMAT=alac\n"))

        draft.defaultFormat = "aac256"
        XCTAssertTrue(draft.isDirty)

        draft.markSaved()
        XCTAssertFalse(draft.isDirty)
    }

    func testApplyWritesOnlyManagedKeysAndNormalizes() {
        var file = EnvFile(contents: """
        # header
        OUTPUT_DIR="~/Music/Old Sets"
        PORT=9000
        """)
        var draft = SettingsDraft(from: file)
        draft.outputDirectory = ""
        draft.defaultFormat = "aac256"

        draft.apply(to: &file)

        XCTAssertEqual(file.value(for: "OUTPUT_DIR"), "~/Music/YouTube Sets")
        XCTAssertEqual(file.value(for: "DEFAULT_FORMAT"), "aac256")
        XCTAssertEqual(file.value(for: "PORT"), "9000", "Unmanaged keys stay put")
        XCTAssertTrue(file.contents.hasPrefix("# header\n"))
    }

    /// A settings file from an earlier build may still carry keys the app
    /// no longer offers; saving must not disturb them.
    func testApplyLeavesRetiredKeysAlone() {
        var file = EnvFile(contents: "OPENAI_API_KEY=sk-old\nOPENAI_MODEL=gpt-4o-mini\n")
        var draft = SettingsDraft(from: file)
        draft.defaultFormat = "aac256"

        draft.apply(to: &file)

        XCTAssertEqual(file.value(for: "OPENAI_API_KEY"), "sk-old")
        XCTAssertEqual(file.value(for: "OPENAI_MODEL"), "gpt-4o-mini")
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
