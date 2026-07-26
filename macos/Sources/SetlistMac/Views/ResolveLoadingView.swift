import SwiftUI

struct ResolveLoadingView: View {
    let sourceURL: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activePhase = 0

    private var presentation: ResolvePresentation {
        ResolvePresentation(reduceMotion: reduceMotion)
    }

    /// The last phase ("Ready to review") only lights up when the resolve
    /// actually finishes and this view is replaced, so the timed
    /// progression holds on the phase before it.
    private var lastTimedPhase: Int {
        max(0, presentation.phases.count - 2)
    }

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            HStack(alignment: .center, spacing: 64) {
                artworkSkeleton
                    .frame(width: 290)

                VStack(alignment: .leading, spacing: 34) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RESOLVING")
                            .font(.caption.weight(.semibold))
                            .tracking(2.2)
                            .foregroundStyle(SetlistTheme.cherry)

                        Text("Reading the room")
                            .font(.system(size: 38, weight: .medium))
                            .tracking(-1.1)
                            .foregroundStyle(SetlistTheme.paper)

                        Text(sourceURL)
                            .font(.callout)
                            .foregroundStyle(SetlistTheme.mutedPaper)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    phaseRail
                }
                .frame(maxWidth: 470, alignment: .leading)
            }
            .frame(maxWidth: SetlistTheme.contentWidth)
            .padding(SetlistTheme.detailPadding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Resolving YouTube set")
        .task {
            // The backend resolve is one blocking call, so step through the
            // phases on a timer to reflect the work that is actually
            // happening, holding on the final in-flight phase.
            while activePhase < lastTimedPhase {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else {
                    return
                }
                if reduceMotion {
                    activePhase += 1
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        activePhase += 1
                    }
                }
            }
        }
    }

    private var artworkSkeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 5)
                .fill(SetlistTheme.paper.opacity(0.09))
                .aspectRatio(1, contentMode: .fit)

            RoundedRectangle(cornerRadius: 4)
                .fill(SetlistTheme.paper.opacity(0.11))
                .frame(width: 210, height: 22)

            RoundedRectangle(cornerRadius: 3)
                .fill(SetlistTheme.paper.opacity(0.07))
                .frame(width: 128, height: 14)
        }
        .modifier(ResolveShimmer(active: presentation.shimmerEnabled))
        .accessibilityHidden(true)
    }

    private var phaseRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.phases.enumerated()), id: \.element.id) {
                index,
                phase in
                let isDone = index < activePhase
                let isActive = index == activePhase
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 0) {
                        ZStack {
                            if isDone {
                                Circle()
                                    .fill(SetlistTheme.cherry)
                                    .frame(width: 18, height: 18)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(SetlistTheme.obsidian)
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Circle()
                                    .stroke(
                                        isActive
                                            ? SetlistTheme.cherry
                                            : SetlistTheme.hairline,
                                        lineWidth: 1.5
                                    )
                                    .frame(width: 18, height: 18)
                                if isActive {
                                    PulsingDot(
                                        animated: presentation.shimmerEnabled
                                    )
                                }
                            }
                        }
                        .frame(width: 18, height: 18)

                        if index < presentation.phases.count - 1 {
                            Rectangle()
                                .fill(
                                    isDone
                                        ? SetlistTheme.cherry.opacity(0.7)
                                        : SetlistTheme.hairline
                                )
                                .frame(width: 1.5, height: 35)
                        }
                    }

                    Text(phase.title)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(
                            isDone || isActive
                                ? SetlistTheme.paper
                                : SetlistTheme.mutedPaper.opacity(0.7)
                        )
                        .padding(.top, -1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(phase.title)
                .accessibilityValue(
                    isDone ? "Done" : isActive ? "In progress" : "Pending"
                )
            }
        }
    }
}

private struct PulsingDot: View {
    let animated: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(SetlistTheme.cherry)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.5 : 1)
            .opacity(pulsing ? 0.55 : 1)
            .onAppear {
                guard animated else {
                    return
                }
                withAnimation(
                    .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                ) {
                    pulsing = true
                }
            }
    }
}

private struct ResolveShimmer: ViewModifier {
    let active: Bool
    @State private var offset: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [
                                .clear,
                                SetlistTheme.paper.opacity(0.12),
                                .clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: geometry.size.width * 0.45)
                        .rotationEffect(.degrees(18))
                        .offset(x: offset * geometry.size.width * 1.4)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard active else {
                    return
                }
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    offset = 1
                }
            }
    }
}
