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
    static let shared: BackendController = {
        let projectRoot = BackendConfiguration.bundled()?.projectRoot
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return BackendController(
            configuration: BackendConfiguration(projectRoot: projectRoot)
        )
    }()

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
        guard FileManager.default.isExecutableFile(
            atPath: configuration.runScriptURL.path
        ) else {
            throw BackendLaunchError.runScriptMissing(
                configuration.runScriptURL.path
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [configuration.runScriptURL.path]
        process.currentDirectoryURL = configuration.projectRoot
        var environment = ProcessInfo.processInfo.environment
        environment["OPEN_BROWSER"] = "0"
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ].joined(separator: ":")
        process.environment = environment

        let logHandle = openLogFile(at: configuration.logFileURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
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

    var errorDescription: String? {
        switch self {
        case .runScriptMissing(let path):
            return "Could not find the Setlist server at \(path). Rebuild the app after moving the project."
        }
    }
}
