import Foundation

enum MusicImportError: LocalizedError, Equatable {
    case noFiles
    case missingFiles([String])
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFiles:
            "There are no finished files to add to Apple Music."
        case .missingFiles(let paths):
            "Some finished files could not be found on disk: "
                + paths.joined(separator: ", ")
        case .scriptFailed(let message):
            "Apple Music could not import the files: \(message)"
        }
    }
}

protocol MusicImporting: Sendable {
    func importFiles(_ paths: [String]) async throws
}

/// Adds finished files to the Apple Music library via Scripting Bridge
/// (osascript), which imports without hijacking playback.
struct AppleMusicImporter: MusicImporting {
    func importFiles(_ paths: [String]) async throws {
        guard !paths.isEmpty else {
            throw MusicImportError.noFiles
        }

        let missing = paths.filter {
            !FileManager.default.fileExists(atPath: $0)
        }
        guard missing.isEmpty else {
            throw MusicImportError.missingFiles(missing)
        }

        let source = Self.appleScriptSource(for: paths)
        try await Self.runOSAScript(source)
    }

    /// Builds the AppleScript that imports the given files. Pure and
    /// testable; paths are escaped for embedding in AppleScript strings.
    static func appleScriptSource(for paths: [String]) -> String {
        let fileList = paths
            .map { "POSIX file \"\(escape($0))\"" }
            .joined(separator: ", ")
        return """
        tell application "Music"
            add {\(fileList)}
        end tell
        """
    }

    static func escape(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runOSAScript(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]

                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(
                        throwing: MusicImportError.scriptFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }

                guard process.terminationStatus == 0 else {
                    let data = errorPipe.fileHandleForReading
                        .readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: MusicImportError.scriptFailed(
                            message?.isEmpty == false
                                ? message!
                                : "osascript exited with status \(process.terminationStatus)"
                        )
                    )
                    return
                }

                continuation.resume()
            }
        }
    }
}
