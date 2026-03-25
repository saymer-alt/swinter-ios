import SwiftUI

struct LiquidBackground: View {
    let connectionState: VPNState

    @State private var phase: CGFloat = 0

    private var accentColor: Color {
        switch connectionState {
        case .disconnected: return Color(red: 0.3, green: 0.4, blue: 0.8)
        case .connecting, .disconnecting: return Color(red: 0.5, green: 0.3, blue: 0.9)
        case .connected: return Color(red: 0.0, green: 0.75, blue: 0.6)
        }
    }

    private var secondaryColor: Color {
        switch connectionState {
        case .disconnected: return Color(red: 0.15, green: 0.2, blue: 0.5)
        case .connecting, .disconnecting: return Color(red: 0.6, green: 0.2, blue: 0.7)
        case .connected: return Color(red: 0.0, green: 0.5, blue: 0.85)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate

                // Base: near-black with slight blue tint
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(red: 0.03, green: 0.04, blue: 0.08))
                )

                // Animated aurora blobs
                let blobs: [(cx: CGFloat, cy: CGFloat, radius: CGFloat, speed: CGFloat, color: Color)] = [
                    (0.3, 0.2, 0.5, 0.15, accentColor.opacity(0.15)),
                    (0.7, 0.4, 0.45, 0.12, secondaryColor.opacity(0.12)),
                    (0.5, 0.7, 0.55, 0.10, Color(red: 0.1, green: 0.2, blue: 0.4).opacity(0.2)),
                    (0.2, 0.6, 0.35, 0.18, accentColor.opacity(0.08)),
                    (0.8, 0.15, 0.3, 0.14, secondaryColor.opacity(0.10)),
                ]

                for blob in blobs {
                    let t = now * blob.speed
                    let x = (blob.cx + sin(t * 1.3) * 0.15) * size.width
                    let y = (blob.cy + cos(t * 0.9) * 0.12) * size.height
                    let r = blob.radius * min(size.width, size.height)

                    let center = CGPoint(x: x, y: y)
                    let gradient = Gradient(colors: [blob.color, blob.color.opacity(0)])

                    context.fill(
                        Circle().path(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: r)
                    )
                }

                // Subtle noise grain overlay
                for _ in 0..<80 {
                    let gx = CGFloat.random(in: 0...size.width)
                    let gy = CGFloat.random(in: 0...size.height)
                    let gs = CGFloat.random(in: 0.5...1.5)
                    context.fill(
                        Circle().path(in: CGRect(x: gx, y: gy, width: gs, height: gs)),
                        with: .color(.white.opacity(Double.random(in: 0.01...0.03)))
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 1.5), value: connectionState)
    }
}
