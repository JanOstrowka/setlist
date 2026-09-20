import Combine
import Foundation

enum BackendStatus: Equatable {
    case idle
    case starting
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Stopped"
        case .starting:
            return "Starting…"
        case .ready:
            return "Ready"
        case .failed:
            return "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "circle"
        case .starting:
            return "clock"
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

/// Identity payload returned by the backend's `/health` endpoint. Attaching
/// requires a matching identity so an unrelated server that happens to hold
/// the port is never mistaken for the Setlist engine.
struct BackendHealth: Codable, Equatable, Sendable {
    let status: String
    let app: String

    var isCompatibleSetlistEngine: Bool {
        status == "ok" && app == "Setlist"
    }
}

@MainActor
final class BackendController: ObservableObject {
    static let shared = BackendController(
        configuration: BackendConfiguration.detect()
    )

    typealias HealthCheck = (URL) async -> BackendHealth?
    typealias Launcher = (BackendConfiguration) throws -> Process

    @Published private(set) var status: BackendStatus = .idle
    private(set) var ownsBackend = false

    let configuration: BackendConfiguration

    private let healthCheck: HealthCheck
    private let launcher: Launcher
    private let retryDelayNanoseconds: UInt64
    private let retryAttempts: Int
    private var process: Process?
    private var isStopping = false

    init(
        configuration: BackendConfiguration,
        healthCheck: @escaping HealthCheck = BackendController.checkHealth,
        launcher: @escaping Launcher = BackendController.launch,
        retryDelayNanoseconds: UInt64 = 250_000_000,
        retryAttempts: Int = 60
    ) {
        self.configuration = configuration
        self.healthCheck = healthCheck
        self.launcher = launcher
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.retryAttempts = retryAttempts
    }

    func start() async {
        guard status != .starting, status != .ready else {
            return
        }

        status = .starting
        if await compatibleEngineResponds() {
            ownsBackend = false
            status = .ready
            return
        }

        do {
            let process = try launcher(configuration)
            self.process = process
            ownsBackend = true
            observeTermination(of: process)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        for _ in 0..<retryAttempts {
            if retryDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
            if await compatibleEngineResponds() {
                status = .ready
                return
            }
        }

        status = .failed("The local server did not become ready.")
    }

    func stop() {
        isStopping = true
        if ownsBackend, let process, process.isRunning {
            process.terminate()
        }
        process = nil
        ownsBackend = false
        status = .idle
        isStopping = false
    }

    func retry() {
        stop()
        Task {
            await start()
        }
    }

    func handleBackendTermination() async {
        guard !isStopping, ownsBackend else {
            return
        }

        process = nil
        ownsBackend = false
        if await compatibleEngineResponds() {
            status = .ready
        } else {
            status = .failed("The local server exited unexpectedly.")
        }
    }

    private func compatibleEngineResponds() async -> Bool {
        guard let health = await healthCheck(configuration.healthURL) else {
            return false
        }
        return health.isCompatibleSetlistEngine
    }

    private func observeTermination(of process: Process) {
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                await self?.handleBackendTermination()
            }
        }
    }

    nonisolated private static func checkHealth(url: URL) async -> BackendHealth? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(BackendHealth.self, from: data)
        } catch {
            return nil
        }
    }

    nonisolated private static func launch(
        configuration: BackendConfiguration
    ) throws -> Process {
        let process: Process
        switch configuration.engine {
        case .source(let projectRoot):
            process = try sourceProcess(
                projectRoot: projectRoot,
                configuration: configuration
            )
        case .bundled(let engine):
            process = try bundledProcess(
                engine: engine,
                configuration: configuration
            )
        }

        let logHandle = openLogFile(at: configuration.logFileURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }

    /// Development: the checkout's `run.sh` owns the venv and `.env`.
    nonisolated private static func sourceProcess(
        projectRoot: URL,
        configuration: BackendConfiguration
    ) throws -> Process {
        let runScript = projectRoot.appendingPathComponent("run.sh")
        guard FileManager.default.isExecutableFile(atPath: runScript.path) else {
            throw BackendLaunchError.runScriptMissing(runScript.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [runScript.path]
        process.currentDirectoryURL = projectRoot
        var environment = ProcessInfo.processInfo.environment
        environment["OPEN_BROWSER"] = "0"
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ].joined(separator: ":")
        process.environment = environment
        return process
    }

    /// Distribution: the relocatable CPython inside the app runs uvicorn
    /// directly. Everything the engine needs is inside the bundle, and
    /// nothing it does may write there (the bundle is code-signed), so
    /// bytecode caching is off and yt-dlp updates go to a user overlay.
    nonisolated private static func bundledProcess(
        engine: BackendConfiguration.BundledEngine,
        configuration: BackendConfiguration
    ) throws -> Process {
        guard engine.isInstalled else {
            throw BackendLaunchError.engineMissing(engine.pythonURL.path)
        }

        try configuration.ensureSettingsFileExists()
        try FileManager.default.createDirectory(
            at: configuration.userPackagesURL,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = engine.pythonURL
        var arguments = [
            "-m", "uvicorn", "app.main:app",
            "--host", "127.0.0.1",
            "--port", String(configuration.port),
        ]
        if FileManager.default.fileExists(atPath: configuration.settingsFileURL.path) {
            arguments += ["--env-file", configuration.settingsFileURL.path]
        }
        process.arguments = arguments
        process.currentDirectoryURL = engine.backendRoot

        // Start from a clean environment: a developer's PYTHONHOME or
        // Homebrew PATH must never leak into a shipped engine.
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                environment[key] = value
            }
        }
        environment["PATH"] = [
            engine.binDirectory.path,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        environment["PYTHONPATH"] = [
            configuration.userPackagesURL.path,
            engine.backendRoot.path,
        ].joined(separator: ":")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["OPEN_BROWSER"] = "0"
        environment["YT_DLP_UPDATE_TARGET"] = configuration.userPackagesURL.path
        process.environment = environment
        return process
    }

    nonisolated private static let logTruncationThresholdBytes = 5_000_000

    /// Opens the backend log for appending, truncating oversized files.
    /// Falls back to the null device so a logging problem never blocks
    /// the engine from starting.
    nonisolated private static func openLogFile(at url: URL) -> FileHandle {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let size = (try? fileManager.attributesOfItem(
                atPath: url.path
            )[.size] as? Int) ?? 0
            if size > logTruncationThresholdBytes {
                try Data().write(to: url)
            } else if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        } catch {
            return FileHandle.nullDevice
        }
    }
}

private enum BackendLaunchError: LocalizedError {
    case runScriptMissing(String)
    case engineMissing(String)

    var errorDescription: String? {
        switch self {
        case .runScriptMissing(let path):
            return "Could not find the Setlist server at \(path). Rebuild the app after moving the project."
        case .engineMissing(let path):
            return "The media engine inside the app is missing (\(path)). Reinstall Setlist from the disk image."
        }
    }
}
