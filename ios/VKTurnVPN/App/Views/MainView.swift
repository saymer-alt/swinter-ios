import SwiftUI

struct MainView: View {
    @EnvironmentObject var vpn: VPNManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Top: Orb + Routing controls
                topSection

                // Active server card
                if let server = vpn.appConfig.activeServer {
                    ActiveServerCard(server: server, state: vpn.state)
                }

                // Connecting status
                if vpn.state == .connecting && !vpn.connectingStatus.isEmpty {
                    Text(vpn.connectingStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 16)
                }

                // Error
                if !vpn.lastError.isEmpty {
                    Text(vpn.lastError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                // Favorites
                favoritesSection

                // (stats now in top section next to orb)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Top Section: Orb + Stats + Controls

    private var topSection: some View {
        HStack(alignment: .center, spacing: 20) {
            // Orb (tap to toggle)
            Button {
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                vpn.toggle()
            } label: {
                StatusOrb(state: vpn.state)
                    .frame(width: 120, height: 120)
            }
            .buttonStyle(OrbButtonStyle())

            // Right side: stats + routing + test
            VStack(spacing: 10) {
                // Connection stats: TIME + UP + DOWN
                if vpn.state == .connected {
                    VStack(spacing: 6) {
                        ConnectionTimer()
                        HStack(spacing: 12) {
                            MiniStat(icon: "arrow.up", value: vpn.uploadSpeed, total: NetworkStats.formatBytes(vpn.totalBytesOut))
                            MiniStat(icon: "arrow.down", value: vpn.downloadSpeed, total: NetworkStats.formatBytes(vpn.totalBytesIn))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                RoutingButton(
                    title: "Routing",
                    subtitle: routingMode,
                    icon: "arrow.triangle.branch",
                    color: .cyan
                ) {
                    // TODO: cycle routing modes
                }

                RoutingButton(
                    title: "Test",
                    subtitle: activeLatency,
                    icon: "bolt.fill",
                    color: .orange
                ) {
                    if let server = vpn.appConfig.activeServer, !server.address.isEmpty {
                        Task {
                            let start = Date()
                            if let url = URL(string: "http://\(server.address)") {
                                var req = URLRequest(url: url)
                                req.timeoutInterval = 5
                                req.httpMethod = "HEAD"
                                _ = try? await URLSession.shared.data(for: req)
                            }
                            let ms = Int(Date().timeIntervalSince(start) * 1000)
                            vpn.updateServerLatency(server.id, latencyMs: ms)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var routingMode: String {
        if vpn.appConfig.routingRules.isEmpty { return "Global" }
        return "Config (\(vpn.appConfig.routingRules.count))"
    }

    private var activeLatency: String {
        if let ms = vpn.appConfig.activeServer?.latencyMs { return "\(ms)ms" }
        return "—"
    }

    // MARK: - Favorites

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !favorites.isEmpty {
                HStack {
                    Text("FAVORITES")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                }

                ForEach(favorites) { server in
                    FavoriteServerRow(
                        server: server,
                        isActive: server.id == vpn.appConfig.activeServerID,
                        isConnected: vpn.state == .connected && server.id == vpn.appConfig.activeServerID
                    ) {
                        vpn.setActiveServer(server.id)
                        if vpn.state == .disconnected {
                            vpn.connect()
                        }
                    }
                }
            }

            if vpn.appConfig.servers.isEmpty {
                Button {
                    // Switch to Servers tab
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Добавить сервер")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var favorites: [Server] {
        vpn.appConfig.servers.filter { $0.isFavorite }
    }
}

// MARK: - Active Server Card

struct ActiveServerCard: View {
    let server: Server
    let state: VPNState

    var body: some View {
        HStack(spacing: 14) {
            // Protocol icon
            Image(systemName: protocolIcon)
                .font(.system(size: 22))
                .foregroundStyle(state == .connected ? .green : .white.opacity(0.4))
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name.isEmpty ? server.address : server.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                HStack(spacing: 8) {
                    Text(server.proto.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))

                    if let turn = server.turnOverlay {
                        Text(turn.source == .max ? "MAX TURN" : "VK TURN")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.cyan)
                    }

                    Text(server.address)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(state == .connected ? Color.green.opacity(0.08) : .white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(state == .connected ? Color.green.opacity(0.2) : .white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var statusColor: Color {
        switch state {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .disconnected: return .white.opacity(0.2)
        }
    }

    private var protocolIcon: String {
        switch server.proto {
        case .wireguard: return "lock.shield.fill"
        case .amneziawg: return "shield.lefthalf.filled"
        case .vless, .vmess: return "arrow.triangle.branch"
        case .trojan: return "bolt.shield.fill"
        case .shadowsocks: return "circle.dashed"
        case .hysteria2: return "hare.fill"
        case .socks5, .http: return "globe"
        }
    }
}

// MARK: - Favorite Server Row

struct FavoriteServerRow: View {
    let server: Server
    let isActive: Bool
    let isConnected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Radio indicator
                Circle()
                    .fill(isActive ? (isConnected ? Color.green : Color.cyan) : .clear)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white.opacity(isActive ? 0 : 0.3), lineWidth: 1))

                Text(server.name.isEmpty ? server.address : server.name)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isActive ? 0.9 : 0.6))

                Spacer()

                Text(server.proto.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))

                if let ms = server.latencyMs {
                    Text("\(ms)ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(latencyColor(ms))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? .white.opacity(0.06) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms < 100 { return .green.opacity(0.8) }
        if ms < 300 { return .yellow.opacity(0.8) }
        return .red.opacity(0.8)
    }
}

// MARK: - Routing Button

struct RoutingButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.2))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Orb Button Style

struct OrbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Status Orb (keep existing)

struct StatusOrb: View {
    let state: VPNState

    @State private var innerRotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3

    private var primaryColor: Color {
        switch state {
        case .disconnected: return Color(red: 0.3, green: 0.35, blue: 0.7)
        case .connecting, .disconnecting: return Color(red: 0.5, green: 0.35, blue: 0.9)
        case .connected: return Color(red: 0.0, green: 0.83, blue: 0.53)
        }
    }

    private var secondaryColor: Color {
        switch state {
        case .disconnected: return Color(red: 0.2, green: 0.25, blue: 0.5)
        case .connecting, .disconnecting: return Color(red: 0.3, green: 0.2, blue: 0.7)
        case .connected: return Color(red: 0.0, green: 0.55, blue: 0.85)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [primaryColor.opacity(glowOpacity), .clear], center: .center, startRadius: 30, endRadius: 80))
                .scaleEffect(pulseScale)

            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))

            Circle()
                .fill(AngularGradient(colors: [primaryColor.opacity(0.6), secondaryColor.opacity(0.3), primaryColor.opacity(0.1), secondaryColor.opacity(0.5), primaryColor.opacity(0.6)], center: .center, angle: .degrees(innerRotation)))
                .padding(6)
                .blur(radius: 12)
                .clipShape(Circle().inset(by: 3))

            // State text
            Text(stateText)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { innerRotation = 360 }
            startPulse()
        }
        .onChange(of: state) { _ in startPulse() }
    }

    private var stateText: String {
        switch state {
        case .disconnected: return "OFF"
        case .connecting: return "..."
        case .connected: return "ON"
        case .disconnecting: return "..."
        }
    }

    private func startPulse() {
        let isActive = state == .connecting || state == .connected
        withAnimation(isActive ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : .easeInOut(duration: 0.5)) {
            pulseScale = isActive ? 1.15 : 1.0
            glowOpacity = isActive ? 0.5 : 0.2
        }
    }
}

// MARK: - Connection Button (legacy, kept for compat)

struct ConnectionButton: View {
    let state: VPNState
    let isConfigured: Bool

    var body: some View {
        EmptyView() // Replaced by orb tap
    }
}

struct LiquidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Mini Stat (for top section)

struct MiniStat: View {
    let icon: String
    let value: String
    var total: String = ""

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if !total.isEmpty {
                Text(total)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - Connection Timer

struct ConnectionTimer: View {
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green.opacity(0.6))
            Text(formatDuration(elapsed))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .onReceive(timer) { _ in elapsed += 1 }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
