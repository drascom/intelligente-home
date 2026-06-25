import SwiftUI

struct OrbView: View {
    var amplitude: Float = 0
    var hue: Double = 0.62  // blue-ish
    var pulsing: Bool = true

    @State private var phase: CGFloat = 0
    @State private var rotation: Double = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = pulsing ? CGFloat(0.5 + 0.5 * sin(t * 1.2)) : 0
            let amp = CGFloat(amplitude)
            let scale = 1.0 + breathe * 0.06 + amp * 0.18

            ZStack {
                // Outer glow ring
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [color(0.95), color(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .blur(radius: 12)
                    .frame(width: 240, height: 240)
                    .scaleEffect(scale + 0.05)
                    .opacity(0.7)

                // Core orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color(1.0), color(0.6), color(0.18)],
                            center: .init(x: 0.4, y: 0.35),
                            startRadius: 5,
                            endRadius: 130
                        )
                    )
                    .frame(width: 200, height: 200)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: color(0.7).opacity(0.6), radius: 30, x: 0, y: 0)
                    .scaleEffect(scale)

                // Highlight
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.55), .clear],
                            center: .init(x: 0.35, y: 0.3),
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .frame(width: 200, height: 200)
                    .scaleEffect(scale)
                    .blendMode(.screen)

                // Rotating shimmer
                Circle()
                    .trim(from: 0, to: 0.35)
                    .stroke(color(0.95).opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 220, height: 220)
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 6) / 6 * 360))
                    .blur(radius: 1.5)
                    .opacity(0.7)
            }
        }
    }

    private func color(_ brightness: Double) -> Color {
        Color(hue: hue, saturation: 0.65, brightness: brightness)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        OrbView(amplitude: 0.3)
    }
}
