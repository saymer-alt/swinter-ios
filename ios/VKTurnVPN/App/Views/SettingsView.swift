import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vpn: VPNManager
    @Environment(\.dismiss) var dismiss

    @State private var showAdvanced = false
    @State private var importText = ""
    @State private var showImportAlert = false
    @State private var showExportSheet = false
    @State private var neLog = ""
    @State private var showLogSheet = false
    @State private var testFeaturesEnabled = UserDefaults.standard.bool(forKey: "test_features")
    @State private var showMaxLogin = false
    @State private var maxLoggedIn = MaxAuthService.shared.isLoggedIn
    @State private var subscribeURL = ""

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color(red: 0.04, green: 0.05, blue: 0.1)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // MAX Account
                        GlassSection(title: "MAX АККАУНТ", icon: "message.fill") {
                            if maxLoggedIn {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green.opacity(0.8))
                                        .font(.system(size: 18))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Вы вошли в MAX")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.8))
                                        Text(MaxAuthService.shared.maskedPhone)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                    Spacer()
                                    Button("Выйти") {
                                        MaxAuthService.shared.logout()
                                        maxLoggedIn = false
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.red.opacity(0.7))
                                }
                            } else {
                                Button {
                                    showMaxLogin = true
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "person.badge.plus")
                                            .font(.system(size: 16))
                                        Text("Войти в MAX")
                                            .font(.system(size: 15, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(LinearGradient(
                                                colors: [Color(red: 0.0, green: 0.7, blue: 0.8), Color(red: 0.3, green: 0.4, blue: 0.9)],
                                                startPoint: .leading, endPoint: .trailing
                                            ))
                                    )
                                }
                                .sheet(isPresented: $showMaxLogin, onDismiss: {
                                    maxLoggedIn = MaxAuthService.shared.isLoggedIn
                                }) {
                                    MaxLoginView()
                                }
                                Text("MAX используется только для получения TURN-серверов. Данные хранятся на устройстве и никуда не передаются. Приложение не получает доступ к остальному функционалу MAX.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.25))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        // TURN Default Target User ID
                        GlassSection(title: "TURN TARGET", icon: "person.fill") {
                            GlassTextField(
                                text: Binding(
                                    get: { vpn.appConfig.settings.defaultTurnTargetUserID },
                                    set: {
                                        vpn.appConfig.settings.defaultTurnTargetUserID = $0
                                        vpn.appConfig.save()
                                    }
                                ),
                                placeholder: "User ID для TURN (напр. 6725252)",
                                icon: "person.fill"
                            )
                            Text("ID пользователя MAX для получения TURN. Используется по умолчанию если не указан в сервере.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.25))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // On-Demand (Always On)
                        GlassSection(title: "АВТОПОДКЛЮЧЕНИЕ", icon: "arrow.clockwise.circle.fill") {
                            GlassToggle(
                                isOn: Binding(
                                    get: { vpn.appConfig.settings.alwaysOn },
                                    set: { vpn.updateOnDemandSettings(alwaysOn: $0) }
                                ),
                                label: "Always On"
                            )

                            if vpn.appConfig.settings.alwaysOn {
                                Text("iOS автоматически переподключит VPN")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.3))
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                GlassTextField(
                                    text: Binding(
                                        get: { vpn.appConfig.settings.ssidExceptions.joined(separator: ", ") },
                                        set: { vpn.updateOnDemandSettings(ssidExceptions: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
                                    ),
                                    placeholder: "WiFi без VPN (SSID через запятую)",
                                    icon: "wifi"
                                )
                            }
                        }

                        // Import
                        GlassSection(title: "ИМПОРТ СЕРВЕРОВ", icon: "square.and.arrow.down") {
                            Button {
                                importServerFromClipboard()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.clipboard")
                                    Text("Из буфера обмена")
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }

                            GlassTextField(
                                text: $subscribeURL,
                                placeholder: "Subscribe URL",
                                icon: "link"
                            )

                            Button {
                                importFromURL()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Импорт с URL")
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(red: 0.0, green: 0.7, blue: 0.9).opacity(0.8))
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(Color(red: 0.0, green: 0.7, blue: 0.9).opacity(0.1))
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(subscribeURL.isEmpty)
                        }

                        // iCloud
                        GlassSection(title: "iCLOUD", icon: "icloud.fill") {
                            GlassToggle(
                                isOn: Binding(
                                    get: { vpn.appConfig.settings.iCloudSyncEnabled },
                                    set: {
                                        vpn.appConfig.settings.iCloudSyncEnabled = $0
                                        vpn.appConfig.save()
                                        if $0 { CloudSync.shared.push(vpn.appConfig) }
                                    }
                                ),
                                label: "Синхронизация iCloud"
                            )
                        }
                        .alert(importText, isPresented: $showImportAlert) {
                            Button("OK") {}
                        }

                        // Test features toggle
                        GlassToggle(
                            isOn: Binding(
                                get: { testFeaturesEnabled },
                                set: {
                                    testFeaturesEnabled = $0
                                    UserDefaults.standard.set($0, forKey: "test_features")
                                    if !$0 { vpn.config.turnSource = .vk }
                                }
                            ),
                            label: "Тестовые фичи"
                        )

                        // Debug log button
                        Button {
                            let defaults = UserDefaults(suiteName: "group.com.swinter.vpn")
                            neLog = defaults?.string(forKey: "tunnel_log") ?? "Лог пуст"
                            showLogSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("NE Log")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .sheet(isPresented: $showLogSheet) {
                            NavigationView {
                                ScrollView {
                                    Text(neLog)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .padding()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .background(Color(red: 0.04, green: 0.05, blue: 0.1))
                                .navigationTitle("NE Log")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Copy") {
                                            UIPasteboard.general.string = neLog
                                        }
                                    }
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("Clear") {
                                            UserDefaults(suiteName: "group.com.swinter.vpn")?.removeObject(forKey: "tunnel_log")
                                            neLog = "Cleared"
                                        }
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

    // MARK: - Import

    private func importServerFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importText = "Буфер пуст"
            showImportAlert = true
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Try as protocol URI (vless://, ss://, trojan://, vmess://)
        if let server = parseServerURI(trimmed) {
            vpn.addServer(server)
            importText = "Сервер добавлен: \(server.name.isEmpty ? server.address : server.name)"
            showImportAlert = true
            return
        }

        // 2. Try as subscribe URL (https://...)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            subscribeURL = trimmed
            importFromURL()
            return
        }

        // 3. Try as base64-encoded URI list
        if let decoded = Data(base64Encoded: trimmed),
           let decodedStr = String(data: decoded, encoding: .utf8) {
            let lines = decodedStr.components(separatedBy: .newlines).filter { !$0.isEmpty }
            var count = 0
            for line in lines {
                if let server = parseServerURI(line.trimmingCharacters(in: .whitespaces)) {
                    vpn.addServer(server)
                    count += 1
                }
            }
            if count > 0 {
                importText = "Импортировано: \(count) серверов"
                showImportAlert = true
                return
            }
        }

        // 4. Try as JSON config
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONDecoder().decode(Server.self, from: data) {
            vpn.addServer(json)
            importText = "Сервер импортирован"
            showImportAlert = true
            return
        }

        importText = "Не удалось распарсить. Вставьте URI сервера (vless://, ss://, trojan://...) или URL подписки (https://...)"
        showImportAlert = true
    }

    private func importFromURL() {
        let urlStr = subscribeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlStr) else { return }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let text = String(data: data, encoding: .utf8) else { return }

                // Extract subscription name from response headers or URL
                let subName = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "subscription-userinfo")
                    ?? url.host ?? "Subscription"

                // Parse lines
                let rawLines = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }

                // Decode base64 if single line
                let lines: [String]
                if rawLines.count == 1, let d = Data(base64Encoded: rawLines[0]),
                   let s = String(data: d, encoding: .utf8) {
                    lines = s.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else {
                    lines = rawLines
                }

                // Parse servers
                var servers: [Server] = []
                for line in lines {
                    if let server = parseServerURI(line) {
                        servers.append(server)
                    }
                }

                guard !servers.isEmpty else {
                    await MainActor.run {
                        importText = "Не найдено серверов по URL"
                        showImportAlert = true
                    }
                    return
                }

                await MainActor.run {
                    // Create or update subscription
                    vpn.importSubscription(
                        name: subName,
                        url: urlStr,
                        servers: servers
                    )
                    importText = "Подписка: \(servers.count) серверов"
                    showImportAlert = true
                    subscribeURL = ""
                }
            } catch {
                await MainActor.run {
                    importText = "Ошибка: \(error.localizedDescription)"
                    showImportAlert = true
                }
            }
        }
    }

    private func applyPreset() {
        if vpn.config.turnSource == .maxCall {
            // MAX Call VPN preset
            vpn.config.maxTargetUserID = "6725252"
            vpn.config.maxCallServerPubkey = "c3906ce5b4f8ac487dc327723194b9f6f511b8222f054161dc9c0df6c9456171"
        } else if vpn.config.turnSource == .max {
            // MAX TURN preset
            vpn.config.maxTargetUserID = "6725252"
            vpn.config.peerAddr = "5.61.39.52:56000"
            vpn.config.wgPrivateKey = "oCDQtT7i7cKt5_sm8EGJA7OMMkvBRe15oyU1GykQeVw"
            vpn.config.wgPublicKey = "_ReTc3sEO68sMMT1dhdXrfOMn-CgTdRWg37RtnGmexs"
            vpn.config.wgAddress = "10.7.0.2/32"
            vpn.config.wgDNS = "1.1.1.1"
            vpn.config.useUDP = true
            vpn.config.numConns = 4
        } else {
            // WireGuard over TURN preset
            vpn.config.vkLink = "https://vk.com/call/join/uMOpfUcn1H6RtPM4tZyMtvleTK_53QhiI7-m5TuHu_U"
            vpn.config.peerAddr = "5.61.39.52:56000"
            vpn.config.wgPrivateKey = "oCDQtT7i7cKt5_sm8EGJA7OMMkvBRe15oyU1GykQeVw"
            vpn.config.wgPublicKey = "_ReTc3sEO68sMMT1dhdXrfOMn-CgTdRWg37RtnGmexs"
            vpn.config.wgAddress = "10.7.0.2/32"
            vpn.config.wgDNS = "1.1.1.1"
            vpn.config.useUDP = true
            vpn.config.numConns = 4
        }
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
