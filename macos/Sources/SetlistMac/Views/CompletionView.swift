import AppKit
import SwiftUI

struct CompletionView: View {
    let workflow: WorkflowController
    let completed: CompletedJob
    let record: HistoryRecord?
    let importer: any MusicImporting

    private enum ImportPhase: Equatable {
        case idle
        case importing
        case imported
        case failed(String)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebrationDone = false
    @State private var importPhase: ImportPhase = .idle

    private var trackNames: [String] {
        completed.outputPaths.map {
            URL(fileURLWithPath: $0)
                .deletingPathExtension()
                .lastPathComponent
        }
    }

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            if celebrationDone || reduceMotion {
                summary
                    .transition(.opacity)
            } else {
                TrackFlowCelebration(
                    trackNames: trackNames,
                    onFinished: {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            celebrationDone = true
                        }
                    }
                )
            }
        }
        .onAppear {
            if reduceMotion {
                celebrationDone = true
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("SET COMPLETE")
                    .font(.caption.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(SetlistTheme.cherry)

                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: celebrationDone)
                    Text(title)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(SetlistTheme.paper)
                }

                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(SetlistTheme.mutedPaper)
            }

            if !completed.outputPaths.isEmpty {
                outputList
            }

            importStatus

            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        addToAppleMusic()
                    } label: {
                        Label(
                            importPhase == .imported
                                ? "Added to Apple Music"
                                : "Add to Apple Music",
                            systemImage: "music.note"
                        )
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SetlistTheme.cherry)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        completed.outputPaths.isEmpty
                            || importPhase == .importing
                            || importPhase == .imported
                    )

                    Button("Reveal in Finder") {
                        revealInFinder()
                    }
                    .disabled(completed.outputPaths.isEmpty)

                    Button("Start Another Set") {
                        workflow.startOver()
                    }
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
        .frame(maxWidth: SetlistTheme.contentWidth, alignment: .leading)
        .padding(SetlistTheme.detailPadding)
    }

    private var title: String {
        if let record, !record.title.isEmpty {
            return record.title
        }
        return "The set is on your Mac"
    }

    private var subtitle: String {
        let count = completed.outputPaths.count
        let files = count == 1 ? "1 file" : "\(count) files"
        let artist = record?.artist ?? ""
        let when = completed.completedAt.formatted(
            date: .abbreviated,
            time: .shortened
        )
        return artist.isEmpty
            ? "\(files) finished \(when)."
            : "\(artist) · \(files) finished \(when)."
    }

    private var outputList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(
                    Array(trackNames.enumerated()),
                    id: \.offset
                ) { index, name in
                    HStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundStyle(SetlistTheme.cherry)
                        Text(name)
                            .font(.callout)
                            .foregroundStyle(SetlistTheme.paper)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.03))
                    )
                    .accessibilityLabel("Finished track \(index + 1): \(name)")
                }
            }
        }
        .frame(maxHeight: 240)
    }

    @ViewBuilder
    private var importStatus: some View {
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
                "All tracks are in your Apple Music library.",
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
    }

    private func addToAppleMusic() {
        let paths = completed.outputPaths
        let importer = importer
        importPhase = .importing
        Task {
            do {
                try await importer.importFiles(paths)
                importPhase = .imported
            } catch {
                importPhase = .failed(
                    (error as? MusicImportError)?.errorDescription
                        ?? String(describing: error)
                )
            }
        }
    }

    private func revealInFinder() {
        let urls = completed.outputPaths.map(URL.init(fileURLWithPath:))
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// The signature completion moment: finished tracks drift down and are
/// absorbed by the Mac, then the summary takes over.
private struct TrackFlowCelebration: View {
    let trackNames: [String]
    let onFinished: () -> Void

    @State private var launched = false

    private var chips: [String] {
        let names = trackNames.isEmpty ? ["Your set"] : trackNames
        return Array(names.prefix(8))
    }

    private var flightDuration: Double {
        0.9 + Double(chips.count) * 0.16
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, name in
                    chip(name)
                        .position(
                            launched
                                ? CGPoint(x: size.width / 2, y: size.height - 130)
                                : startPoint(index: index, in: size)
                        )
                        .opacity(launched ? 0 : 1)
                        .scaleEffect(launched ? 0.35 : 1)
                        .animation(
                            .easeIn(duration: 0.85)
                                .delay(Double(index) * 0.14),
                            value: launched
                        )
                }

                VStack(spacing: 10) {
                    Image(systemName: "macbook")
                        .font(.system(size: 74, weight: .light))
                        .foregroundStyle(SetlistTheme.paper)
                        .symbolEffect(.pulse, isActive: launched)
                    Text("Landing on your Mac…")
                        .font(.callout)
                        .foregroundStyle(SetlistTheme.mutedPaper)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 76)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            launched = true
            Task {
                try? await Task.sleep(for: .seconds(flightDuration))
                onFinished()
            }
        }
    }

    private func startPoint(index: Int, in size: CGSize) -> CGPoint {
        let columns = 4
        let column = index % columns
        let row = index / columns
        let horizontalStep = size.width / CGFloat(columns + 1)
        return CGPoint(
            x: horizontalStep * CGFloat(column + 1),
            y: 120 + CGFloat(row) * 64
        )
    }

    private func chip(_ name: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "music.note")
                .font(.caption)
            Text(name)
                .font(.callout)
                .lineLimit(1)
        }
        .foregroundStyle(SetlistTheme.paper)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(SetlistTheme.cherry.opacity(0.32))
        )
        .overlay(
            Capsule().stroke(SetlistTheme.cherry.opacity(0.6), lineWidth: 1)
        )
        .frame(maxWidth: 230)
    }
}
