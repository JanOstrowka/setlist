import AppKit
import SwiftUI

/// Rich summary of a finished set, shared by the live completion scene
/// and the Recent history detail. Structured around the primary journey:
/// get the tracks into Apple Music, then listen.
struct CompletedSetSummaryView: View {
    let title: String
    let artist: String
    let videoID: String?
    let sourceURL: String
    let outputPaths: [String]
    let completedAt: Date?
    let note: String?
    let importer: any MusicImporting
    let onImported: () -> Void
    let startAnother: (() -> Void)?

    private enum ImportPhase: Equatable {
        case idle
        case importing
        case imported
        case failed(String)
    }

    @State private var importPhase: ImportPhase

    init(
        title: String,
        artist: String,
        videoID: String?,
        sourceURL: String,
        outputPaths: [String],
        completedAt: Date?,
        note: String? = nil,
        alreadyImported: Bool,
        importer: any MusicImporting,
        onImported: @escaping () -> Void,
        startAnother: (() -> Void)? = nil
    ) {
        self.title = title
        self.artist = artist
        self.videoID = videoID
        self.sourceURL = sourceURL
        self.outputPaths = outputPaths
        self.completedAt = completedAt
        self.note = note
        self.importer = importer
        self.onImported = onImported
        self.startAnother = startAnother
        _importPhase = State(initialValue: alreadyImported ? .imported : .idle)
    }

    static func trackNames(from outputPaths: [String]) -> [String] {
        outputPaths.map {
            URL(fileURLWithPath: $0)
                .deletingPathExtension()
                .lastPathComponent
        }
    }

    static func metaLine(
        artist: String,
        trackCount: Int,
        completedAt: Date?
    ) -> String {
        var parts: [String] = []
        if !artist.isEmpty {
            parts.append(artist)
        }
        parts.append(trackCount == 1 ? "1 track" : "\(trackCount) tracks")
        if let completedAt {
            let when = completedAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
            parts.append("Finished \(when)")
        }
        return parts.joined(separator: " · ")
    }

    /// Canonical watch link: URL extras like timestamps are dropped when
    /// the video ID is known.
    static func watchURL(videoID: String?, sourceURL: String) -> URL? {
        if let videoID, !videoID.isEmpty {
            return YouTubePlayerController.watchURL(videoID: videoID)
        }
        return URL(string: sourceURL)
    }

    private var trackNames: [String] {
        Self.trackNames(from: outputPaths)
    }

    private var missingPaths: Set<String> {
        Set(
            outputPaths.filter {
                !FileManager.default.fileExists(atPath: $0)
            }
        )
    }

    private var availablePaths: [String] {
        outputPaths.filter { !missingPaths.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            actionBar
            statusLines
            if !outputPaths.isEmpty {
                trackSection
            }
        }
        .frame(maxWidth: SetlistTheme.contentWidth, alignment: .leading)
        .padding(SetlistTheme.detailPadding)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            artwork
                .frame(width: 112, height: 112)
                .clipShape(.rect(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(SetlistTheme.hairline, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                    Text("SET COMPLETE")
                        .font(.caption.weight(.semibold))
                        .tracking(2.2)
                }
                .foregroundStyle(.green)

                Text(title)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(SetlistTheme.paper)
                    .lineLimit(2)

                Text(
                    Self.metaLine(
                        artist: artist,
                        trackCount: outputPaths.count,
                        completedAt: completedAt
                    )
                )
                .font(.title3)
                .foregroundStyle(SetlistTheme.mutedPaper)
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let videoID, !videoID.isEmpty {
            AsyncImage(
                url: YouTubePlayerController.thumbnailURL(videoID: videoID)
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                artworkPlaceholder
            }
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            SetlistTheme.warmBlack
            Image(systemName: "music.note")
                .font(.system(size: 34))
                .foregroundStyle(SetlistTheme.cherry.opacity(0.7))
        }
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 12) {
                if importPhase == .imported {
                    Button {
                        NSWorkspace.shared.open(URL(string: "music://")!)
                    } label: {
                        Label("Open Apple Music", systemImage: "music.note")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SetlistTheme.cherry)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        addToAppleMusic()
                    } label: {
                        Label("Add to Apple Music", systemImage: "music.note")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SetlistTheme.cherry)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        availablePaths.isEmpty || importPhase == .importing
                    )
                }

                Button("Reveal in Finder") {
                    revealInFinder()
                }
                .disabled(availablePaths.isEmpty)

                if let watchURL = Self.watchURL(
                    videoID: videoID,
                    sourceURL: sourceURL
                ) {
                    Button {
                        NSWorkspace.shared.open(watchURL)
                    } label: {
                        Label(
                            "Watch on YouTube",
                            systemImage: "arrow.up.forward"
                        )
                    }
                }

                if let startAnother {
                    Button("Start Another Set", action: startAnother)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var statusLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch importPhase {
            case .idle:
                EmptyView()
            case .importing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Adding to Apple Music…")
                        .font(.callout)
                        .foregroundStyle(SetlistTheme.mutedPaper)
                }
            case .imported:
                Label(
                    "In your Apple Music library.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if outputPaths.isEmpty {
                Label(
                    "No output files were recorded for this set.",
                    systemImage: "questionmark.folder"
                )
                .font(.callout)
                .foregroundStyle(SetlistTheme.mutedPaper)
            } else if availablePaths.isEmpty {
                Label(
                    "The audio files are no longer at their original "
                        + "location on disk.",
                    systemImage: "questionmark.folder"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if let note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.8))
                    .textSelection(.enabled)
            }
        }
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRACKS")
                .font(.caption.weight(.semibold))
                .tracking(2.2)
                .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.72))

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(
                        Array(zip(outputPaths.indices, outputPaths)),
                        id: \.0
                    ) { index, path in
                        trackRow(index: index, path: path)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private func trackRow(index: Int, path: String) -> some View {
        let name = trackNames[index]
        let missing = missingPaths.contains(path)
        return HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit())
                .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.6))
                .frame(width: 22, alignment: .trailing)
            Text(name)
                .font(.callout)
                .foregroundStyle(SetlistTheme.paper)
                .lineLimit(1)
            Spacer()
            if missing {
                Text("missing")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.85))
            }
        }
        .opacity(missing ? 0.45 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
        )
        .accessibilityLabel(
            missing
                ? "Track \(index + 1): \(name), file missing"
                : "Track \(index + 1): \(name)"
        )
    }

    private func addToAppleMusic() {
        let paths = availablePaths
        let importer = importer
        importPhase = .importing
        Task {
            do {
                try await importer.importFiles(paths)
                importPhase = .imported
                onImported()
            } catch {
                importPhase = .failed(
                    (error as? MusicImportError)?.errorDescription
                        ?? String(describing: error)
                )
            }
        }
    }

    private func revealInFinder() {
        let urls = availablePaths.map(URL.init(fileURLWithPath:))
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
