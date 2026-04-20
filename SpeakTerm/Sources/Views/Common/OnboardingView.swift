import SwiftUI

/// Onboarding flow shown on first launch.
/// 5 skippable cards demonstrating key gestures.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    private let pages: [(icon: String, title: String, description: String)] = [
        ("hand.tap", "Tap to Switch", "Tap any pane to make it active. The active pane has a blue border."),
        ("hand.pinch", "Pinch to Zoom", "Use two fingers to zoom the canvas in and out. See all your panes at once."),
        ("hand.draw", "Two-Finger Pan", "Drag with two fingers to move around the canvas."),
        ("mic.fill", "Hold to Speak", "In voice mode, hold on a pane to dictate. Slide up to send, down to cancel."),
        ("hand.tap.fill", "Double-Tap Focus", "Double-tap a pane to enter focus mode. Double-tap again to exit."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Skip button
            HStack {
                Spacer()
                Button("Skip") { dismiss() }
                    .foregroundStyle(.secondary)
                    .padding()
            }

            Spacer()

            // Page content
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    VStack(spacing: 24) {
                        Image(systemName: page.icon)
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                            .frame(height: 80)

                        Text(page.title)
                            .font(.title2.bold())

                        Text(page.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Spacer()

            // Next / Get Started button
            Button(action: {
                if currentPage < pages.count - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    dismiss()
                }
            }) {
                Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
    }
}
