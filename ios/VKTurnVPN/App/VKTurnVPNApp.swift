import SwiftUI

@main
struct SwinterApp: App {
    @StateObject private var vpnManager = VPNManager()

    var body: some Scene {
        WindowGroup {
            TabRootView()
                .environmentObject(vpnManager)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if url.scheme == "swinter" && url.host == "toggle" {
                        vpnManager.toggle()
                    }
                }
        }
    }
}

// MARK: - Stats Bar

struct StatsBar: View {
    @EnvironmentObject var vpn: VPNManager
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 24) {
            StatItem(icon: "clock.fill", label: "TIME", value: formatDuration(elapsed))
            StatItem(icon: "arrow.up.circle.fill", label: "UP", value: vpn.uploadSpeed)
            StatItem(icon: "arrow.down.circle.fill", label: "DOWN", value: vpn.downloadSpeed)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .onReceive(timer) { _ in
            if vpn.state == .connected {
                elapsed += 1
            }
        }
    }

    func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

struct StatItem: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
                .tracking(1.5)
        }
        .frame(maxWidth: .infinity)
    }
}
