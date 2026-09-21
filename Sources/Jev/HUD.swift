import SwiftUI

final class HUDModel: ObservableObject {
    enum Shape { case hidden, pill, card }

    @Published var shape: Shape = .hidden
    @Published var title = "Listening..."
    @Published var subtitle = ""
    @Published var hint = ""
    @Published var probs: [Double] = []
    @Published var pulse = false

    func show(_ shape: Shape, title: String, subtitle: String = "", hint: String = "", probs: [Double] = []) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            self.shape = shape
            self.title = title
            self.subtitle = subtitle
            self.hint = hint
            self.probs = probs
        }
    }

    func hide() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { shape = .hidden }
    }

    /// Micro-scale pulse on the title when an action is confirmed.
    func confirm() {
        pulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { self.pulse = false }
    }
}

struct HUDView: View {
    @ObservedObject var m: HUDModel

    private let slide = AnyTransition.asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity),
        removal: .move(edge: .top).combined(with: .opacity)
    )

    var body: some View {
        let card = m.shape == .card
        let outline = RoundedRectangle(cornerRadius: card ? 30 : 22, style: .continuous)
        VStack(spacing: 5) {
            if card {
                DensityField(probs: m.probs).frame(height: 64).transition(.opacity)
            }
            ZStack {
                Text(m.title)
                    .font(.system(size: card ? 34 : 15, weight: card ? .bold : .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .id(m.title)
                    .transition(slide)
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .scaleEffect(m.pulse ? 1.12 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.45), value: m.pulse)
            if card {
                ZStack {
                    Text(m.subtitle).font(.system(size: 13)).lineLimit(1).id(m.subtitle).transition(slide)
                }
                .frame(maxWidth: .infinity)
                .clipped()
                .opacity(0.75)
                Text(m.hint).font(.system(size: 11, design: .monospaced)).opacity(0.4)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 3)
        .padding(.horizontal, 18)
        .frame(width: card ? 380 : 220, height: card ? 190 : 44)
        .background {
            ZStack {
                Color.black
                if m.shape != .hidden { NoiseField().opacity(card ? 0.3 : 0.5) }
            }
        }
        .clipShape(outline)
        .overlay(outline.strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .scaleEffect(m.shape == .hidden ? 0.7 : 1, anchor: .bottom)
        .opacity(m.shape == .hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 36)
    }
}

// MARK: - Procedural visuals

private func hash3(_ x: Int, _ y: Int, _ z: Int) -> Double {
    var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ z &* 1_442_695_041)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    return Double((h ^ (h >> 16)) & 0xffff) / 65535
}

/// Trilinear value noise, z is time.
private func noise3(_ x: Double, _ y: Double, _ z: Double) -> Double {
    let xi = Int(floor(x)), yi = Int(floor(y)), zi = Int(floor(z))
    let s = { (t: Double) in t * t * (3 - 2 * t) }
    let fx = s(x - floor(x)), fy = s(y - floor(y)), fz = s(z - floor(z))
    let lerp = { (a: Double, b: Double, t: Double) in a + (b - a) * t }
    let plane = { (k: Int) in
        lerp(lerp(hash3(xi, yi, k), hash3(xi + 1, yi, k), fx),
             lerp(hash3(xi, yi + 1, k), hash3(xi + 1, yi + 1, k), fx), fy)
    }
    return lerp(plane(zi), plane(zi + 1), fz)
}

/// Monochrome pixel ripple shown while the agent is active.
// ponytail: CPU Canvas (~3k cells/frame), not a Metal shader — SwiftPM can't compile .metal; move to
// ShaderLibrary + colorEffect if this ever shows up in a profile.
struct NoiseField: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let cell = 5.0
                for y in 0..<Int(size.height / cell) + 1 {
                    for x in 0..<Int(size.width / cell) + 1 {
                        let n = noise3(Double(x) * 0.16, Double(y) * 0.16 + t * 0.35, t * 0.7) * 0.65
                            + noise3(Double(x) * 0.45 - t * 0.5, Double(y) * 0.45, t * 1.3) * 0.35
                        let level = floor(max(0, n - 0.35) * 8) / 5  // quantised: reads as pixels, not fog
                        guard level > 0 else { continue }
                        let rect = CGRect(x: Double(x) * cell, y: Double(y) * cell, width: cell - 1, height: cell - 1)
                        ctx.fill(Path(rect), with: .color(.white.opacity(min(1, level))))
                    }
                }
            }
        }
    }
}

/// Dot histogram shaped like a bell curve; it re-forms over whichever option Jev currently favours.
struct DensityField: View {
    let probs: [Double]

    private final class Curve { var v = [Double](repeating: 0, count: DensityField.cols) }
    @State private var curve = Curve()
    private static let cols = 44, rows = 10

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let target = Self.target(probs, t)
                for i in 0..<Self.cols {
                    curve.v[i] += (target[i] - curve.v[i]) * 0.14  // ease toward the new distribution
                    let h = curve.v[i] * Double(Self.rows)
                    for j in 0..<Self.rows where Double(j) < h {
                        let twinkle = 0.5 + 0.5 * hash3(i, j, Int(t * 10))
                        let x = (Double(i) + 0.5) / Double(Self.cols) * size.width
                        let y = size.height - (Double(j) + 0.5) / Double(Self.rows) * size.height
                        let dot = CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)
                        ctx.fill(Path(ellipseIn: dot), with: .color(.white.opacity(min(1, h - Double(j)) * twinkle)))
                    }
                }
            }
        }
    }

    /// Mixture of Gaussians, one per option weighted by its probability; wide and centred while undecided.
    static func target(_ probs: [Double], _ t: Double) -> [Double] {
        let centers: [(Double, Double)] = probs.isEmpty
            ? [(0.5, 1)]
            : probs.enumerated().map { ((Double($0) + 0.5) / Double(probs.count), $1) }
        let sigma = probs.isEmpty ? 0.17 + 0.03 * sin(t * 2.2) : 0.05 + 0.14 * (1 - (probs.max() ?? 0))
        let raw = (0..<cols).map { i -> Double in
            let x = (Double(i) + 0.5) / Double(cols)
            return centers.reduce(0) { $0 + $1.1 * exp(-pow(x - $1.0, 2) / (2 * sigma * sigma)) }
        }
        let peak = max(raw.max() ?? 0, 0.0001)
        return raw.map { $0 / peak * 0.95 }
    }
}
