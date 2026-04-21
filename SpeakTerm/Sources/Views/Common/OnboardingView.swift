import SwiftUI

/// iOS-native onboarding bottom sheet with 5 gesture guide cards.
/// Matches the design prototype's Onboarding component.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    private let cards: [(icon: String, title: String, body: String)] = [
        ("mic.fill",
         "Hold to speak",
         "Press and hold any pane. Keep your finger still for a moment to start recording. The direction you release in chooses send, insert, AI → shell, or cancel."),
        ("hand.draw",
         "One finger scrolls",
         "Press and drag immediately to scroll pane history. Double-tap any word to select, then drag the handles."),
        ("hand.pinch",
         "Two fingers for the canvas",
         "Pinch to zoom, drag to pan. Double-tap empty space to fit the canvas to your screen."),
        ("mic.badge.xmark",
         "Two modes",
         "Tap the icon in the top bar to switch between Voice and Keyboard. Popping up the keyboard switches automatically."),
        ("command",
         "Quick Keys appear when needed",
         "When a pane asks for input — a y/n prompt, an agent confirmation — keys surface right below it. Tap without switching focus."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Grabber
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 14)

            // Page dots + Skip
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<cards.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == currentPage ? Color.stAccent : Color.secondary.opacity(0.3))
                            .frame(width: i == currentPage ? 20 : 6, height: 6)
                            .animation(.easeInOut(duration: 0.26), value: currentPage)
                    }
                }
                Spacer()
                Button("Skip") { dismiss() }
                    .font(.system(size: 17))
                    .foregroundStyle(Color.stAccent)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            // Demo area (placeholder with icon)
            let card = cards[currentPage]
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.tertiarySystemGroupedBackground))
                .frame(height: 180)
                .overlay {
                    Image(systemName: card.icon)
                        .font(.system(size: 48))
                        .foregroundStyle(Color.stAccent)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

            // Title + body
            VStack(alignment: .leading, spacing: 8) {
                Text(card.title)
                    .font(.system(size: 28, weight: .bold))

                Text(card.body)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Primary button
            Button(action: {
                if currentPage < cards.count - 1 {
                    withAnimation(.easeInOut(duration: 0.26)) { currentPage += 1 }
                } else {
                    dismiss()
                }
            }) {
                Text(currentPage < cards.count - 1 ? "Continue" : "Get started")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.stAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -50, currentPage < cards.count - 1 {
                        withAnimation { currentPage += 1 }
                    } else if value.translation.width > 50, currentPage > 0 {
                        withAnimation { currentPage -= 1 }
                    }
                }
        )
    }
}
