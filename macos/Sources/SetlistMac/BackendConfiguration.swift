import Foundation

/// Where the Python media engine lives and how it is configured.
///
/// Two shapes exist:
///
/// - **Bundled** (distribution builds): the engine ships inside the `.app`
///   under `Contents/Resources/engine` — a relocatable CPython, the
///   `app/` + `web/` backend, and static `ffmpeg`/`ffprobe`. User
///   settings live in `~/Library/Application Support/Setlist/settings.env`.
/// - **Source** (development): the engine is a source checkout launched
///   through its `run.sh`, configured by the checkout's `.env`.
struct BackendConfiguration {
    static let defaultPort = 8765

    enum Engine: Equatable {
        case bundled(BundledEngine)
        case source(projectRoot: URL)
    }

    /// Layout produced by `scripts/build_macos_app.sh`.
    struct BundledEngine: Equatable {
        /// `Setlist.app/Contents/Resources/engine`
        let root: URL

        var pythonURL: URL {
            root.appendingPathComponent("python/bin/python3")
        }

        /// Contains the `app/` package and the `web/` assets it serves.
        var backendRoot: URL {
            root.appendingPathComponent("backend", isDirectory: true)
        }

        /// Static `ffmpeg` and `ffprobe`; prepended to the engine's PATH.
        var binDirectory: URL {
            root.appendingPathComponent("bin", isDirectory: true)
        }

        var isInstalled: Bool {
            FileManager.default.isExecutableFile(atPath: pythonURL.path)
        }
    }

    let engine: Engine

    /// User-editable `KEY=value` settings loaded into the engine's
    /// environment (`OUTPUT_DIR`, `DEFAULT_FORMAT`, `PORT`, …).
    let settingsFileURL: URL

    let port: Int

    /// `~/Library/Application Support/Setlist`: settings, history, and the
    /// writable package overlay for yt-dlp updates.
    let applicationSupportURL: URL

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var healthURL: URL {
        baseURL.appendingPathComponent("health")
    }

    /// The bundled engine never writes inside the sealed `.app`; yt-dlp
    /// updates land here and shadow the bundled copy via `PYTHONPATH`.
    var userPackagesURL: URL {
        applicationSupportURL.appendingPathComponent("packages", isDirectory: true)
    }

    /// Backend output goes to a log file rather than a pipe held by the
    /// app: a pipe dies with the app, and a surviving backend then fails
    /// with EPIPE on its next write. The file also keeps engine logs
    /// available for debugging.
    var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Setlist/backend.log")
    }

    /// Where finished sets are written, honoring `OUTPUT_DIR` in the
    /// settings file and the engine's own default otherwise.
    var outputDirectoryURL: URL {
        let raw = settings().value(for: "OUTPUT_DIR")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "~/Music/YouTube Sets"
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    var isBundled: Bool {
        if case .bundled = engine {
            return true
        }
        return false
    }

    init(
        engine: Engine,
        settingsFileURL: URL,
        applicationSupportURL: URL = BackendConfiguration.defaultApplicationSupportURL
    ) {
        self.engine = engine
        self.settingsFileURL = settingsFileURL
        self.applicationSupportURL = applicationSupportURL
        self.port = Self.readPort(from: settingsFileURL)
    }

    /// Development configuration: a source checkout with its `.env`.
    init(projectRoot: URL) {
        self.init(
            engine: .source(projectRoot: projectRoot),
            settingsFileURL: projectRoot.appendingPathComponent(".env")
        )
    }

    /// A fresh read of the settings file; callers may change it at any time.
    func settings() -> EnvFile {
        EnvFile(contentsOf: settingsFileURL)
    }

    /// Creates the settings file from the template on first launch so the
    /// user always has something discoverable to edit.
    func ensureSettingsFileExists() throws {
        guard !FileManager.default.fileExists(atPath: settingsFileURL.path) else {
            return
        }
        try EnvFile(contents: Self.settingsTemplate).write(to: settingsFileURL)
    }

    static let settingsTemplate = """
    # Setlist settings. Changes apply after the engine restarts
    # (Settings… → Save, or the menu bar icon → Restart Engine).
    # Setlist needs no account or API key; everything runs on this Mac.

    # Where finished sets are saved.
    OUTPUT_DIR="~/Music/YouTube Sets"

    # alac (lossless, larger) or aac256.
    DEFAULT_FORMAT=alac

    # Local port for the engine; change it only if something else uses it.
    PORT=8765
    """

    static var defaultApplicationSupportURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Setlist", isDirectory: true)
    }

    // MARK: - Detection

    /// Resolves the engine for this process, in priority order:
    /// 1. `SETLIST_PROJECT_ROOT` (developer override → source checkout);
    /// 2. an engine bundled inside the app;
    /// 3. `SetlistProjectRoot` in Info.plist (source-linked dev build);
    /// 4. the current directory, so `swift run` from the checkout works.
    static func detect(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportURL: URL = defaultApplicationSupportURL
    ) -> BackendConfiguration {
        if let override = environment["SETLIST_PROJECT_ROOT"], !override.isEmpty {
            return BackendConfiguration(
                projectRoot: URL(fileURLWithPath: override, isDirectory: true)
            )
        }

        if let resources = bundle.resourceURL {
            let bundled = BundledEngine(
                root: resources.appendingPathComponent("engine", isDirectory: true)
            )
            if bundled.isInstalled {
                return BackendConfiguration(
                    engine: .bundled(bundled),
                    settingsFileURL: applicationSupportURL
                        .appendingPathComponent("settings.env"),
                    applicationSupportURL: applicationSupportURL
                )
            }
        }

        if let path = bundle.object(forInfoDictionaryKey: "SetlistProjectRoot") as? String,
           !path.isEmpty {
            return BackendConfiguration(
                projectRoot: URL(fileURLWithPath: path, isDirectory: true)
            )
        }

        return BackendConfiguration(
            projectRoot: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        )
    }

    private static func readPort(from settingsURL: URL) -> Int {
        guard let raw = EnvFile(contentsOf: settingsURL).value(for: "PORT"),
              let port = Int(raw),
              (1...65_535).contains(port) else {
            return defaultPort
        }
        return port
    }
}
