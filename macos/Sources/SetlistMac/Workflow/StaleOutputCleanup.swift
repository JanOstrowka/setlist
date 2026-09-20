import Foundation

/// Tidies up after a set is run again with edits: whatever the previous
/// run produced that the new run did not rewrite goes to the Trash, so a
/// retitled or removed track does not linger next to the new files.
///
/// Everything is moved to the Trash rather than deleted, and only paths
/// the app itself recorded as outputs are ever touched.
struct StaleOutputCleanup: Sendable {
    /// Moves one item to the Trash. Injected so tests can observe it.
    var trash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Files a set folder can hold without counting as "still in use".
    private static let folderJunk: Set<String> = ["cover.jpg", ".DS_Store"]

    /// Trashes previous outputs that are not among the current ones, then
    /// any previous set folder left holding nothing but cover art. Folders
    /// that still hold a current output are always kept. Best effort: a
    /// file that cannot be trashed is simply left where it is.
    ///
    /// With no current outputs nothing is touched: an empty list means the
    /// new run's files are not known yet, not that there are none.
    func removeStale(previous: [String], current: [String]) {
        guard !previous.isEmpty, !current.isEmpty else {
            return
        }
        let fileManager = FileManager.default
        let currentSet = Set(current)
        let currentFolders = Set(
            current.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        )

        var candidateFolders: [String] = []
        for path in previous where !currentSet.contains(path) {
            let url = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: path) else {
                continue
            }
            try? trash(url)
            let folder = url.deletingLastPathComponent().path
            if !currentFolders.contains(folder), !candidateFolders.contains(folder) {
                candidateFolders.append(folder)
            }
        }

        for folder in candidateFolders {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: folder),
                  contents.allSatisfy(Self.folderJunk.contains) else {
                continue
            }
            try? trash(URL(fileURLWithPath: folder, isDirectory: true))
        }
    }
}
