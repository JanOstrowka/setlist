import Foundation
import XCTest
@testable import SetlistMac

final class BackendConfigurationTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func testReadsPortFromEnvFile() throws {
        let directory = try makeTemporaryDirectory()
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
        XCTAssertEqual(configuration.engine, .source(projectRoot: directory))
        XCTAssertFalse(configuration.isBundled)
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

    func testOutputDirectoryHonorsSettingsAndExpandsTilde() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "OUTPUT_DIR=\"~/Music/Sets Test\"\n".write(
            to: directory.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let configuration = BackendConfiguration(projectRoot: directory)

        XCTAssertEqual(
            configuration.outputDirectoryURL.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/Sets Test").path
        )
    }

    func testOutputDirectoryDefaultsWhenUnset() {
        let configuration = BackendConfiguration(
            projectRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        XCTAssertTrue(
            configuration.outputDirectoryURL.path.hasSuffix("/Music/YouTube Sets")
        )
    }

    func testEnsureSettingsFileWritesTemplateOnce() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.env")
        let configuration = BackendConfiguration(
            engine: .bundled(.init(root: directory)),
            settingsFileURL: settingsURL,
            applicationSupportURL: directory
        )

        try configuration.ensureSettingsFileExists()
        var file = EnvFile(contentsOf: settingsURL)
        XCTAssertEqual(file.value(for: "PORT"), "8765")
        XCTAssertEqual(file.value(for: "OPENAI_API_KEY"), "")

        file.set("sk-test", for: "OPENAI_API_KEY")
        try file.write(to: settingsURL)
        try configuration.ensureSettingsFileExists()

        XCTAssertEqual(
            EnvFile(contentsOf: settingsURL).value(for: "OPENAI_API_KEY"),
            "sk-test",
            "An existing settings file must never be overwritten"
        )
        XCTAssertEqual(
            configuration.userPackagesURL,
            directory.appendingPathComponent("packages", isDirectory: true)
        )
    }

    // MARK: - Detection

    func testDetectPrefersProjectRootOverride() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = BackendConfiguration.detect(
            bundle: .main,
            environment: ["SETLIST_PROJECT_ROOT": directory.path],
            applicationSupportURL: directory
        )

        XCTAssertEqual(
            configuration.engine,
            .source(projectRoot: URL(fileURLWithPath: directory.path, isDirectory: true))
        )
    }

    func testDetectFindsBundledEngineInResources() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleURL = try makeFakeAppBundle(in: directory, withEngine: true)
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let support = directory.appendingPathComponent("Support", isDirectory: true)

        let configuration = BackendConfiguration.detect(
            bundle: bundle,
            environment: [:],
            applicationSupportURL: support
        )

        guard case .bundled(let engine) = configuration.engine else {
            return XCTFail("Expected a bundled engine, got \(configuration.engine)")
        }
        XCTAssertTrue(engine.isInstalled)
        XCTAssertEqual(engine.backendRoot.lastPathComponent, "backend")
        XCTAssertEqual(engine.binDirectory.lastPathComponent, "bin")
        XCTAssertEqual(
            configuration.settingsFileURL,
            support.appendingPathComponent("settings.env")
        )
        XCTAssertTrue(configuration.isBundled)
    }

    func testDetectFallsBackToInfoPlistProjectRoot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleURL = try makeFakeAppBundle(
            in: directory,
            withEngine: false,
            projectRoot: "/tmp/setlist-checkout"
        )
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        let configuration = BackendConfiguration.detect(
            bundle: bundle,
            environment: [:],
            applicationSupportURL: directory
        )

        XCTAssertEqual(
            configuration.engine,
            .source(projectRoot: URL(fileURLWithPath: "/tmp/setlist-checkout", isDirectory: true))
        )
    }

    /// Builds just enough of a `.app` for `Bundle` to load: an Info.plist
    /// and, optionally, an executable `Resources/engine/python/bin/python3`.
    private func makeFakeAppBundle(
        in directory: URL,
        withEngine: Bool,
        projectRoot: String? = nil
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent("Fake.app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )

        var info: [String: Any] = [
            "CFBundleIdentifier": "com.jan.setlist.tests.\(UUID().uuidString)",
            "CFBundleName": "Fake",
            "CFBundlePackageType": "APPL",
        ]
        if let projectRoot {
            info["SetlistProjectRoot"] = projectRoot
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        if withEngine {
            let bin = resources.appendingPathComponent("engine/python/bin", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bin,
                withIntermediateDirectories: true
            )
            let python = bin.appendingPathComponent("python3")
            try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: python.path
            )
        }
        return bundleURL
    }
}
