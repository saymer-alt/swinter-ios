import SwiftUI

struct ConfigTab: View {
    @EnvironmentObject var vpn: VPNManager

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.1)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Import Config
                        ConfigImportSection()

                        Divider()
                            .background(.white.opacity(0.1))

                        // Proxy Groups
                        ProxyGroupsView()

                        Divider()
                            .background(.white.opacity(0.1))

                        // Scenes
                        ScenesView()

                        Divider()
                            .background(.white.opacity(0.1))

                        // Routing Rules
                        RoutingRulesView()

                        // DNS Config
                        DNSConfigView()

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Config")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Config Import

struct ConfigImportSection: View {
    @EnvironmentObject var vpn: VPNManager
    @State private var configURL = ""
    @State private var showAlert = false
    @State private var alertMessage = ""

    private let presets = [
        ("RU Geo (dlisin)", "https://raw.githubusercontent.com/dlisin/shadowrocket-config/master/shadowrocket.conf"),
        ("RU Geo Extended (misha)", "https://raw.githubusercontent.com/misha-tgshv/shadowrocket-configuration-file/main/conf/sr_ru_geo.conf"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ROUTING CONFIG")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()

                if !vpn.appConfig.settings.configURL.isEmpty {
                    Button {
                        vpn.refreshConfig()
                        alertMessage = "Обновляю конфиг..."
                        showAlert = true
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .padding(.horizontal, 4)

            // Current config URL
            if !vpn.appConfig.settings.configURL.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.cyan)
                    Text(vpn.appConfig.settings.configURL)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }

            // URL input
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Config URL (.conf)", text: $configURL)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .autocapitalization(.none)
                    .keyboardType(.URL)

                Button {
                    guard !configURL.isEmpty else { return }
                    vpn.importConfig(from: configURL)
                    alertMessage = "Загрузка конфига..."
                    showAlert = true
                    configURL = ""
                } label: {
                    Text("Import")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
            }
            .padding(10)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            // Presets
            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { name, url in
                    Button {
                        vpn.importConfig(from: url)
                        alertMessage = "Загрузка \(name)..."
                        showAlert = true
                    } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                }
            }

            // Rules count
            Text("\(vpn.appConfig.routingRules.count) правил загружено")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.horizontal, 4)
        }
        .alert(alertMessage, isPresented: $showAlert) {
            Button("OK") {}
        }
    }
}

// MARK: - DNS Config

struct DNSConfigView: View {
    @EnvironmentObject var vpn: VPNManager

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("DNS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                    TextField("DNS Servers (comma-separated)", text: Binding(
                        get: { vpn.appConfig.dns.servers.joined(separator: ", ") },
                        set: {
                            vpn.appConfig.dns.servers = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            vpn.appConfig.save()
                        }
                    ))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
                    .autocapitalization(.none)
                }
                .padding(12)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                    TextField("DoH URL (optional)", text: Binding(
                        get: { vpn.appConfig.dns.dohURL },
                        set: {
                            vpn.appConfig.dns.dohURL = $0
                            vpn.appConfig.save()
                        }
                    ))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                }
                .padding(12)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.06), lineWidth: 0.5))
        }
    }
}
