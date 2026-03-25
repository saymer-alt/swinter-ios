import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vpn: VPNManager
    @Environment(\.dismiss) var dismiss

    @State private var showAdvanced = false

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color(red: 0.04, green: 0.05, blue: 0.1)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // VK Link section
                        GlassSection(title: "VK ЗВОНОК", icon: "video.fill") {
                            GlassTextField(
                                text: $vpn.config.vkLink,
                                placeholder: "https://vk.com/call/join/...",
                                icon: "link"
                            )

                            Text("Создай звонок на vk.com/call и скопируй ссылку")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        // Server section
                        GlassSection(title: "СЕРВЕР", icon: "server.rack") {
                            GlassTextField(
                                text: $vpn.config.peerAddr,
                                placeholder: "IP:порт (напр. 5.61.39.52:56000)",
                                icon: "globe"
                            )
                        }

                        // WireGuard section
                        GlassSection(title: "WIREGUARD", icon: "lock.shield.fill") {
                            GlassTextField(
                                text: $vpn.config.wgPrivateKey,
                                placeholder: "Приватный ключ клиента",
                                icon: "key.fill",
                                isSecure: true
                            )

                            GlassTextField(
                                text: $vpn.config.wgPublicKey,
                                placeholder: "Публичный ключ сервера",
                                icon: "key.horizontal.fill"
                            )

                            HStack(spacing: 12) {
                                GlassTextField(
                                    text: $vpn.config.wgAddress,
                                    placeholder: "10.7.0.2/32",
                                    icon: "number"
                                )

                                GlassTextField(
                                    text: $vpn.config.wgDNS,
                                    placeholder: "1.1.1.1",
                                    icon: "antenna.radiowaves.left.and.right"
                                )
                            }
                        }

                        // Advanced
                        DisclosureGroup(isExpanded: $showAdvanced) {
                            VStack(spacing: 12) {
                                GlassTextField(
                                    text: $vpn.config.turnHost,
                                    placeholder: "Авто (оставь пустым)",
                                    icon: "arrow.triangle.swap"
                                )

                                HStack(spacing: 12) {
                                    GlassToggle(
                                        isOn: $vpn.config.useUDP,
                                        label: "UDP режим"
                                    )

                                    GlassToggle(
                                        isOn: Binding(
                                            get: { vpn.config.numConns > 1 },
                                            set: { vpn.config.numConns = $0 ? 16 : 1 }
                                        ),
                                        label: "Мульти-поток"
                                    )
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 13))
                                Text("Дополнительно")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.4))
                        }
                        .tint(.white.opacity(0.4))
                        .padding(.horizontal, 4)

                        // Preset button
                        Button {
                            applyPreset()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.clipboard")
                                Text("Вставить конфиг сервера")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(.white.opacity(0.06), lineWidth: 0.5)
                            )
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        vpn.saveConfig()
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.0, green: 0.83, blue: 0.9))
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }

    private func applyPreset() {
        // Preset from our server setup
        vpn.config.peerAddr = "5.61.39.52:56000"
        vpn.config.wgPrivateKey = "oCDQtT7i7cKt5_sm8EGJA7OMMkvBRe15oyU1GykQeVw"
        vpn.config.wgPublicKey = "_ReTc3sEO68sMMT1dhdXrfOMn-CgTdRWg37RtnGmexs"
        vpn.config.wgAddress = "10.7.0.2/32"
        vpn.config.wgDNS = "1.1.1.1"
        vpn.config.useUDP = true
        vpn.config.numConns = 4
    }
}

// MARK: - Glass Components

struct GlassSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
            }
            .foregroundStyle(.white.opacity(0.35))
            .padding(.horizontal, 4)

            VStack(spacing: 10) {
                content
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}

struct GlassTextField: View {
    @Binding var text: String
    let placeholder: String
    var icon: String = ""
    var isSecure: Bool = false

    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 10) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 20)
            }

            if isSecure && !isRevealed {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.2)))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.2)))
                    .font(.system(size: 14, design: isSecure ? .monospaced : .default))
                    .foregroundColor(.white.opacity(0.85))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            if isSecure {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

struct GlassToggle: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color(red: 0.0, green: 0.7, blue: 0.9))
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}
