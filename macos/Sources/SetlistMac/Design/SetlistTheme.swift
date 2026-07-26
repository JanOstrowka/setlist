import SwiftUI

enum SetlistTheme {
    static let obsidian = Color(
        red: 0.075,
        green: 0.064,
        blue: 0.064
    )
    static let warmBlack = Color(
        red: 0.105,
        green: 0.088,
        blue: 0.086
    )
    static let cherry = Color(
        red: 0.72,
        green: 0.13,
        blue: 0.20
    )
    static let paper = Color(
        red: 0.96,
        green: 0.91,
        blue: 0.84
    )
    static let mutedPaper = Color(
        red: 0.72,
        green: 0.66,
        blue: 0.61
    )
    static let hairline = Color.white.opacity(0.11)

    static let detailPadding: CGFloat = 48
    static let contentWidth: CGFloat = 860
}

struct SetlistDetailBackground: View {
    var body: some View {
        ZStack {
            SetlistTheme.obsidian

            RadialGradient(
                colors: [
                    SetlistTheme.cherry.opacity(0.18),
                    .clear,
                ],
                center: .topLeading,
                startRadius: 30,
                endRadius: 720
            )

            Rectangle()
                .fill(.white.opacity(0.025))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 112)
        }
        .ignoresSafeArea()
    }
}
