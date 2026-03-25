import SwiftUI

struct MainView: View {
    @EnvironmentObject var vpn: VPNManager

    @State private var buttonScale: CGFloat = 1.0
    @State private var orbPulse: CGFloat = 1.0
    @State private var showConfigHint = false

    private var isConfigured: Bool {
        !vpn.config.vkLink.isEmpty && !vpn.config.peerAddr.isEmpty && !vpn.config.wgPrivateKey.isEmpty
    }

    var body: some View {
        VStack(spacing: 32) {
            // Status orb
            StatusOrb(state: vpn.state)
                .frame(width: 180, height: 180)

            // Status text
            VStack(spacing: 8) {
                Text(statusTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(statusSubtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            // Connect button
            Button {
                handleTap()
            } label: {
                ConnectionButton(state: vpn.state, isConfigured: isConfigured)
            }
            .buttonStyle(LiquidButtonStyle())
            .disabled(vpn.state == .connecting || vpn.state == .disconnecting)

            if !isConfigured && vpn.state == .disconnected {
                Text("Настрой подключение в ⚙️")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
    }

    private var statusTitle: String {
        switch vpn.state {
        case .disconnected: return "Отключено"
        case .connecting: return "Подключение..."
        case .connected: return "Защищено"
        case .disconnecting: return "Отключение..."
        }
    }

    private var statusSubtitle: String {
        switch vpn.state {
        case .disconnected: return "Трафик не защищён"
        case .connecting: return vpn.connectingStatus.isEmpty ? "Устанавливаем TURN-туннель" : vpn.connectingStatus
        case .connected: return "Через VK TURN → VPS"
        case .disconnecting: return "Закрываем соединение"
        }
    }

    private func handleTap() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        switch vpn.state {
        case .disconnected:
            if isConfigured {
                vpn.connect()
            }
        case .connected:
            vpn.disconnect()
        default:
            break
        }
    }
}

// MARK: - Status Orb

struct StatusOrb: View {
    let state: VPNState

    @State private var innerRotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3

    private var primaryColor: Color {
        switch state {
        case .disconnected: return Color(red: 0.3, green: 0.35, blue: 0.5)
        case .connecting, .disconnecting: return Color(red: 0.5, green: 0.35, blue: 0.9)
        case .connected: return Color(red: 0.0, green: 0.83, blue: 0.53)
        }
    }

    private var secondaryColor: Color {
        switch state {
        case .disconnected: return Color(red: 0.2, green: 0.25, blue: 0.4)
        case .connecting, .disconnecting: return Color(red: 0.3, green: 0.2, blue: 0.7)
        case .connected: return Color(red: 0.0, green: 0.55, blue: 0.85)
        }
    }

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [primaryColor.opacity(glowOpacity), .clear],
                        center: .center,
                        startRadius: 50,
                        endRadius: 120
                    )
                )
                .scaleEffect(pulseScale)

            // Glass orb background
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.25), .white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )

            // Inner rotating gradient
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            primaryColor.opacity(0.6),
                            secondaryColor.opacity(0.3),
                            primaryColor.opacity(0.1),
                            secondaryColor.opacity(0.5),
                            primaryColor.opacity(0.6),
                        ],
                        center: .center,
                        angle: .degrees(innerRotation)
                    )
                )
                .padding(8)
                .blur(radius: 15)
                .clipShape(Circle().inset(by: 4))

            // Center icon
            Image(systemName: state == .connected ? "checkmark.shield.fill" : "shield.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white.opacity(0.9), .white.opacity(0.5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: primaryColor.opacity(0.5), radius: 10)

            // Specular highlight
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .padding(4)
                .mask(
                    Circle()
                        .padding(4)
                )
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                innerRotation = 360
            }
            startPulse()
        }
        .onChange(of: state) { _ in
            startPulse()
        }
    }

    private func startPulse() {
        let isActive = state == .connecting || state == .connected
        withAnimation(
            isActive
                ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                : .easeInOut(duration: 0.5)
        ) {
            pulseScale = isActive ? 1.15 : 1.0
            glowOpacity = isActive ? 0.5 : 0.2
        }
    }
}

// MARK: - Connection Button

struct ConnectionButton: View {
    let state: VPNState
    let isConfigured: Bool

    private var buttonColor: Color {
        switch state {
        case .disconnected: return isConfigured ? Color(red: 0.0, green: 0.7, blue: 0.9) : Color(red: 0.3, green: 0.3, blue: 0.4)
        case .connecting, .disconnecting: return Color(red: 0.5, green: 0.35, blue: 0.9)
        case .connected: return Color(red: 0.9, green: 0.25, blue: 0.35)
        }
    }

    private var buttonText: String {
        switch state {
        case .disconnected: return isConfigured ? "Подключиться" : "Не настроено"
        case .connecting: return "Подключение..."
        case .connected: return "Отключить"
        case .disconnecting: return "Отключение..."
        }
    }

    private var buttonIcon: String {
        switch state {
        case .disconnected: return isConfigured ? "bolt.fill" : "exclamationmark.triangle.fill"
        case .connecting, .disconnecting: return "hourglass"
        case .connected: return "xmark"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if state == .connecting || state == .disconnecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.8)
            } else {
                Image(systemName: buttonIcon)
                    .font(.system(size: 16, weight: .semibold))
            }

            Text(buttonText)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(buttonColor.opacity(0.3))

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(buttonColor.opacity(0.25))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [buttonColor.opacity(0.5), buttonColor.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: buttonColor.opacity(0.3), radius: 15, y: 5)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state)
    }
}

struct LiquidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
