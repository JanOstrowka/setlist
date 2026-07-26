import Foundation
import XCTest
@testable import SetlistMac

final class MusicImporterTests: XCTestCase {
    func testScriptListsEveryFile() {
        let source = AppleMusicImporter.appleScriptSource(
            for: ["/Music/a.m4a", "/Music/b.m4a"]
        )

        XCTAssertTrue(source.contains("POSIX file \"/Music/a.m4a\""))
        XCTAssertTrue(source.contains("POSIX file \"/Music/b.m4a\""))
        XCTAssertTrue(source.contains("tell application \"Music\""))
        XCTAssertTrue(source.contains("add {"))
    }

    func testScriptEscapesQuotesAndBackslashes() {
        let source = AppleMusicImporter.appleScriptSource(
            for: ["/Music/mix \"live\" \\ set.m4a"]
        )

        XCTAssertTrue(
            source.contains(
                "POSIX file \"/Music/mix \\\"live\\\" \\\\ set.m4a\""
            )
        )
    }

    func testImportRejectsEmptyFileList() async {
        let importer = AppleMusicImporter()

        do {
            try await importer.importFiles([])
            XCTFail("Expected MusicImportError.noFiles")
        } catch let error as MusicImportError {
            XCTAssertEqual(error, .noFiles)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testImportRejectsMissingFiles() async {
        let importer = AppleMusicImporter()
        let bogus = "/nonexistent/\(UUID().uuidString).m4a"

        do {
            try await importer.importFiles([bogus])
            XCTFail("Expected MusicImportError.missingFiles")
        } catch let error as MusicImportError {
            XCTAssertEqual(error, .missingFiles([bogus]))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
