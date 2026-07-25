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

@MainActor
final class BackendController: ObservableObject {
    static let shared: BackendController = {
        let projectRoot = BackendConfiguration.bundled()?.projectRoot
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return BackendController(
            configuration: BackendConfiguration(projectRoot: projectRoot)
        )
    }()

    typealias HealthCheck = (URL) async -> Bool
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
        if await healthCheck(configuration.healthURL) {
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
            if await healthCheck(configuration.healthURL) {
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
        if await healthCheck(configuration.healthURL) {
            status = .ready
        } else {
            status = .failed("The local server exited unexpectedly.")
        }
    }

    private func observeTermination(of process: Process) {
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                await self?.handleBackendTermination()
            }
        }
    }

    nonisolated private static func checkHealth(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
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

        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            FileHandle.standardError.write(data)
        }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return process
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
