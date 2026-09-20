import AppKit
import SwiftUI

struct CompletionView: View {
    let workflow: WorkflowController
    let completed: CompletedJob
    let record: HistoryRecord?
    let importer: any MusicImporting

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebrationDone = false

    private var trackNames: [String] {
        CompletedSetSummaryView.trackNames(from: completed.outputPaths)
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
        CompletedSetSummaryView(
            title: title,
            artist: record?.artist ?? "",
            videoID: record?.videoID,
            sourceURL: record?.sourceURL ?? "",
            outputPaths: completed.outputPaths,
            completedAt: completed.completedAt,
            note: record?.errorSummary,
            alreadyImported: record?.importedAt != nil,
            importer: importer,
            onImported: { [workflow] in
                workflow.markImported(recordID: completed.recordID)
            },
            startAnother: { [workflow] in
                workflow.startOver()
            },
            edit: { [workflow] in
                Task {
                    await workflow.reopen(recordID: completed.recordID)
                }
            }
        )
    }

    private var title: String {
        if let record, !record.title.isEmpty {
            return record.title
        }
        return "The set is on your Mac"
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
