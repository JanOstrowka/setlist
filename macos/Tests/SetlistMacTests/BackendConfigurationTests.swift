import Foundation
import XCTest
@testable import SetlistMac

final class BackendConfigurationTests: XCTestCase {
    func testReadsPortFromEnvFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        # Setlist settings
        OUTPUT_DIR="~/Music/YouTube Sets"
        PORT = "9123"
        """.write(
            to: directory.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let configuration = BackendConfiguration(projectRoot: directory)

        XCTAssertEqual(configuration.port, 9123)
        XCTAssertEqual(
            configuration.healthURL.absoluteString,
            "http://127.0.0.1:9123/health"
        )
    }

    func testFallsBackToDefaultPort() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let configuration = BackendConfiguration(projectRoot: missingDirectory)

        XCTAssertEqual(configuration.port, 8765)
    }

    func testBackendLogLivesInUserLogsDirectory() {
        let configuration = BackendConfiguration(
            projectRoot: FileManager.default.temporaryDirectory
        )

        XCTAssertTrue(
            configuration.logFileURL.path.hasSuffix(
                "Library/Logs/Setlist/backend.log"
            )
        )
    }
}
