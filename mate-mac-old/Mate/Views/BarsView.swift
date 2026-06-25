import SwiftUI

struct BarsView: View {
    var level: Float
    var barCount: Int = 28

    @State private var seeds: [CGFloat] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<barCount, id: \.self) { i in
                    bar(index: i, t: t)
                }
            }
            .frame(height: 180)
            .padding(.horizontal, 24)
        }
        .onAppear {
            if seeds.isEmpty {
                seeds = (0..<barCount).map { _ in CGFloat.random(in: 0.3...1.0) }
            }
        }
    }

    @ViewBuilder
    private func bar(index i: Int, t: TimeInterval) -> some View {
        let seed = seeds.indices.contains(i) ? seeds[i] : 1.0
        let center = CGFloat(barCount) / 2
        let dist = abs(CGFloat(i) - center) / center  // 0 center, 1 edges
        let centerWeight = 1.0 - pow(dist, 1.4) * 0.6
        let wave = CGFloat(0.5 + 0.5 * sin(t * 4 + Double(i) * 0.5))
        let lvl = max(0.04, CGFloat(level) * centerWeight * (0.6 + 0.6 * wave) * seed)
        let height = max(8, lvl * 180)

        Capsule()
            .fill(
                LinearGradient(
                    colors: [Color(hue: 0.55, saturation: 0.6, brightness: 0.95),
                             Color(hue: 0.7, saturation: 0.7, brightness: 0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 6, height: height)
            .shadow(color: Color(hue: 0.6, saturation: 0.7, brightness: 0.8).opacity(0.6),
                    radius: 6, x: 0, y: 0)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        BarsView(level: 0.5)
    }
}
