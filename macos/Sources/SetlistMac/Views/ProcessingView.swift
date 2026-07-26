import SwiftUI

struct ProcessingView: View {
    let workflow: WorkflowController
    let processing: ProcessingState

    @State private var board: TrackProgressBoard?

    private var tracks: [APITrack] {
        processing.frozenDraft.split
            ? processing.frozenDraft.tracklist.tracks
            : []
    }

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            VStack(alignment: .leading, spacing: 28) {
                header
                StageRail(currentStage: processing.stage)
                overallProgress

                if !tracks.isEmpty {
                    TrackProgressList(
                        tracks: tracks,
                        board: board ?? TrackProgressBoard(
                            trackCount: tracks.count
                        )
                    )
                }

                Spacer(minLength: 0)

                footer
            }
            .frame(
                maxWidth: SetlistTheme.contentWidth,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(SetlistTheme.detailPadding)
        }
        .onAppear {
            var next = TrackProgressBoard(trackCount: tracks.count)
            next.apply(processing)
            board = next
        }
        .onChange(of: processing) { _, newValue in
            var next = board ?? TrackProgressBoard(trackCount: tracks.count)
            next.apply(newValue)
            board = next
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IN PRODUCTION")
                .font(.caption.weight(.semibold))
                .tracking(2.2)
                .foregroundStyle(SetlistTheme.cherry)
            Text(
                processing.frozenDraft.metadata.title.isEmpty
                    ? "Producing the set"
                    : processing.frozenDraft.metadata.title
            )
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(SetlistTheme.paper)
            if !processing.frozenDraft.metadata.artist.isEmpty {
                Text(processing.frozenDraft.metadata.artist)
                    .font(.title3)
                    .foregroundStyle(SetlistTheme.mutedPaper)
            }
        }
    }

    private var overallProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    processing.message.isEmpty
                        ? processing.stage.displayTitle
                        : processing.message
                )
                .font(.body)
                .foregroundStyle(SetlistTheme.paper)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: processing.message)

                Spacer()

                Text("\(Int(processing.percent.rounded()))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SetlistTheme.paper)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(processing.percent.rounded()))
            }

            ProgressView(value: min(max(processing.percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(SetlistTheme.cherry)
                .animation(.easeOut(duration: 0.4), value: processing.percent)
                .accessibilityLabel("Overall progress")
                .accessibilityValue("\(Int(processing.percent.rounded())) percent")

            if let detail = transferDetail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SetlistTheme.mutedPaper)
            }
        }
    }

    private var transferDetail: String? {
        guard processing.stage == .download else {
            return nil
        }
        var parts: [String] = []
        if let downloaded = processing.downloadedBytes,
           let total = processing.totalBytes, total > 0 {
            let formatter = ByteCountFormatStyle(style: .file)
            parts.append(
                "\(formatter.format(Int64(downloaded))) of "
                    + formatter.format(Int64(total))
            )
        }
        if let speed = processing.speedBytesPerSecond, speed > 0 {
            parts.append(
                ByteCountFormatStyle(style: .file)
                    .format(Int64(speed)) + "/s"
            )
        }
        if let eta = processing.etaSeconds, eta > 0 {
            parts.append("about \(TrackTime.format(eta)) left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel Production", role: .destructive) {
                workflow.cancelProcessing()
            }
            .controlSize(.large)
        }
    }
}

struct StageRail: View {
    let currentStage: HistoryStage

    private static let stages: [(HistoryStage, String, String)] = [
        (.download, "Download", "arrow.down.circle"),
        (.encode, "Encode", "waveform.circle"),
        (.split, "Split", "scissors.circle"),
        (.tag, "Tag", "tag.circle"),
    ]

    private var currentPosition: Int {
        switch currentStage {
        case .resolving, .reviewing, .submitting, .queued:
            -1
        case .download:
            0
        case .encode:
            1
        case .split:
            2
        case .tag:
            3
        case .done:
            4
        case .error, .cancelled, .unknown:
            -1
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { position, stage in
                let (_, title, symbol) = stage
                stageBadge(
                    position: position,
                    title: title,
                    symbol: symbol
                )
                if position < Self.stages.count - 1 {
                    Rectangle()
                        .fill(
                            position < currentPosition
                                ? SetlistTheme.cherry
                                : SetlistTheme.hairline
                        )
                        .frame(height: 2)
                        .frame(maxWidth: 56)
                        .padding(.horizontal, 6)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard currentPosition >= 0, currentPosition < Self.stages.count else {
            return "Preparing production stages"
        }
        return "Production stage: \(Self.stages[currentPosition].1)"
    }

    private func stageBadge(
        position: Int,
        title: String,
        symbol: String
    ) -> some View {
        let isDone = position < currentPosition
        let isActive = position == currentPosition
        return HStack(spacing: 7) {
            Image(systemName: isDone ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 17, weight: .medium))
                .symbolEffect(.pulse, isActive: isActive)
            Text(title)
                .font(.callout.weight(isActive ? .semibold : .regular))
        }
        .foregroundStyle(
            isDone || isActive
                ? SetlistTheme.paper
                : SetlistTheme.mutedPaper.opacity(0.55)
        )
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(
                isActive
                    ? SetlistTheme.cherry.opacity(0.28)
                    : Color.white.opacity(0.04)
            )
        )
        .overlay(
            Capsule().stroke(
                isActive ? SetlistTheme.cherry : SetlistTheme.hairline,
                lineWidth: 1
            )
        )
    }
}

struct TrackProgressList: View {
    let tracks: [APITrack]
    let board: TrackProgressBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TRACKS")
                    .font(.caption.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(SetlistTheme.cherry)
                Spacer()
                Text("\(board.readyCount) of \(tracks.count) ready")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SetlistTheme.mutedPaper)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(tracks.indices, id: \.self) { index in
                            trackRow(index: index)
                                .id(index)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: board.activeIndex) { _, active in
                    guard let active else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(active, anchor: .center)
                    }
                }
            }
        }
    }

    private func trackRow(index: Int) -> some View {
        let status = board.statuses.indices.contains(index)
            ? board.statuses[index]
            : .pending
        let track = tracks[index]
        return HStack(spacing: 11) {
            statusIcon(status)
                .frame(width: 20)

            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit())
                .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.65))

            Text(track.title.isEmpty ? "Untitled track" : track.title)
                .font(.callout)
                .foregroundStyle(
                    status == .pending
                        ? SetlistTheme.mutedPaper.opacity(0.72)
                        : SetlistTheme.paper
                )
                .lineLimit(1)

            Spacer()

            Text(statusTitle(status))
                .font(.caption)
                .foregroundStyle(statusTint(status))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(
                    status == .cutting || status == .tagging
                        ? SetlistTheme.cherry.opacity(0.13)
                        : Color.white.opacity(0.025)
                )
        )
        .animation(.easeInOut(duration: 0.25), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Track \(index + 1), \(track.title), \(statusTitle(status))"
        )
    }

    @ViewBuilder
    private func statusIcon(_ status: TrackProgressBoard.TrackStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.5))
        case .cutting:
            Image(systemName: "scissors")
                .foregroundStyle(SetlistTheme.cherry)
                .symbolEffect(.pulse)
        case .tagging:
            Image(systemName: "tag.fill")
                .foregroundStyle(SetlistTheme.cherry)
                .symbolEffect(.pulse)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private func statusTitle(_ status: TrackProgressBoard.TrackStatus) -> String {
        switch status {
        case .pending:
            "Waiting"
        case .cutting:
            "Cutting"
        case .tagging:
            "Tagging"
        case .ready:
            "Ready"
        }
    }

    private func statusTint(_ status: TrackProgressBoard.TrackStatus) -> Color {
        switch status {
        case .pending:
            SetlistTheme.mutedPaper.opacity(0.6)
        case .cutting, .tagging:
            SetlistTheme.cherry
        case .ready:
            .green
        }
    }
}
