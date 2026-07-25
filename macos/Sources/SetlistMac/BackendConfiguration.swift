import Foundation

struct BackendConfiguration {
    static let defaultPort = 8765

    let projectRoot: URL
    let port: Int

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var healthURL: URL {
        baseURL.appendingPathComponent("health")
    }

    var runScriptURL: URL {
        projectRoot.appendingPathComponent("run.sh")
    }

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        self.port = Self.readPort(
            from: projectRoot.appendingPathComponent(".env")
        )
    }

    static func bundled() -> BackendConfiguration? {
        if let override = ProcessInfo.processInfo.environment["SETLIST_PROJECT_ROOT"],
           !override.isEmpty {
            return BackendConfiguration(
                projectRoot: URL(fileURLWithPath: override, isDirectory: true)
            )
        }

        guard let path = Bundle.main.object(
            forInfoDictionaryKey: "SetlistProjectRoot"
        ) as? String, !path.isEmpty else {
            return nil
        }

        return BackendConfiguration(
            projectRoot: URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    private static func readPort(from envURL: URL) -> Int {
        guard let contents = try? String(contentsOf: envURL, encoding: .utf8) else {
            return defaultPort
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
            guard key == "PORT" else {
                continue
            }

            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let port = Int(value), (1...65_535).contains(port) {
                return port
            }
        }

        return defaultPort
    }
}
