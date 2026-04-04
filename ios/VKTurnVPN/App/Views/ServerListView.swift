import SwiftUI

struct ServerListView: View {
    @EnvironmentObject var vpn: VPNManager
    @State private var showAddServer = false
    @State private var showQRScanner = false
    @State private var editingServer: Server?
    @State private var editingSubscription: Subscription?
    @State private var isPinging = false
    @State private var importMessage = ""
    @State private var showImportMessage = false
    @State private var expandedSubscriptions: Set<UUID> = []
    @State private var showFileImporter = false

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.1)
                    .ignoresSafeArea()

                if vpn.appConfig.servers.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        // Ping all
                        Button {
                            pingAll()
                        } label: {
                            Image(systemName: isPinging ? "antenna.radiowaves.left.and.right" : "wifi.exclamationmark")
                                .font(.system(size: 15))
                        }
                        .disabled(isPinging)

                        // QR Scanner
                        Button {
                            showQRScanner = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 16))
                        }

                        // Import from file (.conf)
                        Button {
                            showFileImporter = true
                        } label: {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 15))
                        }

                        // Add server
                        Button {
                            showAddServer = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddServer) {
                ServerEditView(server: nil) { newServer in
                    vpn.addServer(newServer)
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    // Reuse SettingsView's parseURI (TODO: extract to shared)
                    if let server = parseServerURI(code) {
                        vpn.addServer(server)
                        importMessage = "Добавлен: \(server.name.isEmpty ? server.address : server.name)"
                    } else {
                        importMessage = "Не удалось распарсить QR"
                    }
                    showImportMessage = true
                }
            }
            .sheet(item: $editingServer) { server in
                ServerEditView(server: server) { updated in
                    vpn.updateServer(updated)
                }
            }
            .alert(importMessage, isPresented: $showImportMessage) {
                Button("OK") {}
            }
            .sheet(item: $editingSubscription) { sub in
                SubscriptionEditView(subscription: sub)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.text, .data]) { result in
                if case .success(let url) = result {
                    importFromFile(url)
                }
            }
        }
    }

    // MARK: - Server List (grouped by subscription)

    private var serverList: some View {
        List {
            // Test All button (prominent)
            Section {
                Button {
                    pingAll()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isPinging ? "antenna.radiowaves.left.and.right" : "bolt.horizontal.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(isPinging ? "Тестирование..." : "Проверить все серверы")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if isPinging {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(red: 0.0, green: 0.6, blue: 0.9).opacity(0.3))
                    )
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isPinging)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Standalone servers (no subscription)
            let standalone = vpn.appConfig.servers.filter { $0.subscriptionID == nil }
            if !standalone.isEmpty {
                Section {
                    ForEach(standalone) { server in
                        serverRow(server)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            vpn.removeServer(standalone[index].id)
                        }
                    }
                } header: {
                    Text("СЕРВЕРЫ")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            // Subscription groups (Shadowrocket-style)
            ForEach(vpn.appConfig.subscriptions) { sub in
                Section {
                    // Subscription header (collapsible, with refresh + info)
                    SubscriptionHeader(
                        sub: sub,
                        serverCount: vpn.appConfig.servers.filter { $0.subscriptionID == sub.id }.count,
                        onRefresh: { vpn.refreshSubscription(sub) },
                        onEdit: { editingSubscription = sub },
                        isExpanded: expandedSubscriptions.contains(sub.id)
                    ) {
                        if expandedSubscriptions.contains(sub.id) {
                            expandedSubscriptions.remove(sub.id)
                        } else {
                            expandedSubscriptions.insert(sub.id)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    // Servers (shown when expanded)
                    if expandedSubscriptions.contains(sub.id) {
                        let subServers = vpn.appConfig.servers.filter { $0.subscriptionID == sub.id }
                        ForEach(subServers) { server in
                            serverRow(server)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func serverRow(_ server: Server) -> some View {
        ServerRow(
            server: server,
            isActive: server.id == vpn.appConfig.activeServerID,
            onTap: { vpn.setActiveServer(server.id) },
            onEdit: { editingServer = server }
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.visible)
        .listRowSeparatorTint(.white.opacity(0.06))
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .swipeActions(edge: .leading) {
            Button {
                vpn.toggleFavorite(server.id)
            } label: {
                Label(server.isFavorite ? "Unfav" : "Fav", systemImage: server.isFavorite ? "star.slash.fill" : "star.fill")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                vpn.removeServer(server.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.3))

            Text("Нет серверов")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))

            Text("Добавьте сервер для подключения")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.35))

            Button {
                showAddServer = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Добавить сервер")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color(red: 0.0, green: 0.7, blue: 0.9).opacity(0.3))
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Ping

    private func pingAll() {
        isPinging = true
        Task {
            for i in vpn.appConfig.servers.indices {
                let address = vpn.appConfig.servers[i].address
                if !address.isEmpty {
                    // Simple TCP ping
                    let start = Date()
                    if let url = URL(string: "http://\(address)") {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 5
                        request.httpMethod = "HEAD"
                        do {
                            _ = try await URLSession.shared.data(for: request)
                        } catch {}
                    }
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    vpn.updateServerLatency(vpn.appConfig.servers[i].id, latencyMs: ms)
                }
            }
            isPinging = false
        }
    }

    // MARK: - File Import (.conf)

    private func importFromFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            importMessage = "Не удалось прочитать файл"
            showImportMessage = true
            return
        }

        // Parse WireGuard/AmneziaWG .conf format
        if let server = parseWGConf(content, fileName: url.lastPathComponent) {
            vpn.addServer(server)
            importMessage = "Импортирован: \(server.name)"
            showImportMessage = true
            return
        }

        // Try as URI list
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var count = 0
        for line in lines {
            if let server = parseServerURI(line.trimmingCharacters(in: .whitespaces)) {
                vpn.addServer(server)
                count += 1
            }
        }
        importMessage = count > 0 ? "Импортировано: \(count) серверов" : "Не удалось распарсить файл"
        showImportMessage = true
    }

    /// Parse WireGuard/AmneziaWG .conf file format
    private func parseWGConf(_ content: String, fileName: String) -> Server? {
        var iface: [String: String] = [:]
        var peer: [String: String] = [:]
        var section = ""

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[Interface]") { section = "interface"; continue }
            if trimmed.hasPrefix("[Peer]") { section = "peer"; continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0], value = parts[1]

            if section == "interface" { iface[key] = value }
            else if section == "peer" { peer[key] = value }
        }

        guard let privateKey = iface["PrivateKey"], let publicKey = peer["PublicKey"] else { return nil }
        let endpoint = peer["Endpoint"] ?? ""
        let name = fileName.replacingOccurrences(of: ".conf", with: "")

        // Check if AmneziaWG (has Jc, S1, H1 etc.)
        let isAWG = iface["Jc"] != nil || iface["S1"] != nil || iface["H1"] != nil

        if isAWG {
            var server = Server(name: name, address: endpoint, proto: .amneziawg)
            server.protocolConfig = .amneziawg(AmneziaWGConfig(
                privateKey: privateKey,
                publicKey: publicKey,
                presharedKey: peer["PresharedKey"] ?? "",
                peerAddress: endpoint,
                wgAddress: iface["Address"] ?? "10.8.0.2/24",
                dns: iface["DNS"] ?? "1.1.1.1",
                mtu: Int(iface["MTU"] ?? "1280") ?? 1280,
                jc: Int(iface["Jc"] ?? "4") ?? 4,
                jmin: Int(iface["Jmin"] ?? "40") ?? 40,
                jmax: Int(iface["Jmax"] ?? "70") ?? 70,
                s1: Int(iface["S1"] ?? "0") ?? 0,
                s2: Int(iface["S2"] ?? "0") ?? 0,
                h1: Int(iface["H1"] ?? "1") ?? 1,
                h2: Int(iface["H2"] ?? "2") ?? 2,
                h3: Int(iface["H3"] ?? "3") ?? 3,
                h4: Int(iface["H4"] ?? "4") ?? 4
            ))
            return server
        } else {
            var server = Server(name: name, address: endpoint, proto: .wireguard)
            server.protocolConfig = .wireguard(WireGuardConfig(
                privateKey: privateKey,
                publicKey: publicKey,
                presharedKey: peer["PresharedKey"] ?? "",
                peerAddress: endpoint,
                wgAddress: iface["Address"] ?? "10.7.0.2/32",
                dns: iface["DNS"] ?? "1.1.1.1",
                mtu: Int(iface["MTU"] ?? "1280") ?? 1280
            ))
            return server
        }
    }
}  // end ServerListView

// MARK: - Subscription Header (Shadowrocket-style)

struct SubscriptionHeader: View {
    let sub: Subscription
    let serverCount: Int
    let onRefresh: () -> Void
    let onEdit: () -> Void
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.name.isEmpty ? sub.url : sub.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)

                    if let date = sub.lastUpdated {
                        Text(date, style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }

                Spacer()

                Text("\(serverCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))

                Button { onRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.0, green: 0.85, blue: 1.0))
                }
                .buttonStyle(.plain)

                Button { onEdit() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.0, green: 0.85, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Subscription Edit View (like Shadowrocket)

struct SubscriptionEditView: View {
    @EnvironmentObject var vpn: VPNManager
    @Environment(\.dismiss) var dismiss
    let subscription: Subscription

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Type")
                        Spacer()
                        Text("Subscribe")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Text("URL")
                        Spacer()
                        Text(subscription.url)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack {
                        Text("Servers")
                        Spacer()
                        Text("\(subscription.serverIDs.count)")
                            .foregroundStyle(.secondary)
                    }

                    if let date = subscription.lastUpdated {
                        HStack {
                            Text("Updated")
                            Spacer()
                            Text(date, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Auto Update")
                        Spacer()
                        Text(subscription.autoUpdate ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Remarks")
                        Spacer()
                        Text(subscription.name)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = subscription.url
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.cyan)
                            Text("Copy URL")
                        }
                    }

                    Button {
                        vpn.refreshSubscription(subscription)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.cyan)
                            Text("Refresh")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        vpn.removeSubscription(subscription.id)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete")
                            Spacer()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.1))
            .navigationTitle("Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Server Row

struct ServerRow: View {
    let server: Server
    let isActive: Bool
    let onTap: () -> Void    // tap on row = edit
    let onEdit: () -> Void

    @EnvironmentObject var vpn: VPNManager

    var body: some View {
        HStack(spacing: 12) {
            // Radio button — tap to select active
            Button {
                vpn.setActiveServer(server.id)
            } label: {
                ZStack {
                    Circle()
                        .stroke(isActive ? Color(red: 0.0, green: 0.85, blue: 0.5) : .white.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if isActive {
                        Circle()
                            .fill(Color(red: 0.0, green: 0.85, blue: 0.5))
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .buttonStyle(.plain)

            // Protocol icon
            Image(systemName: protocolIcon)
                .font(.system(size: 16))
                .foregroundStyle(protocolColor)
                .frame(width: 28)

            // Server info
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name.isEmpty ? server.address : server.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))

                HStack(spacing: 6) {
                    Text(server.proto.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))

                    if let turn = server.turnOverlay {
                        Text(turn.source == .max ? "MAX TURN" : "VK TURN")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(red: 0.0, green: 0.85, blue: 1.0).opacity(0.8))
                    }

                    Text(server.address)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Latency
            if let ms = server.latencyMs {
                Text("\(ms)ms")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(latencyColor(ms))
            }

            // Edit button (large tap area)
            Button { onEdit() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.vertical, 6)
        .background(isActive ? Color(red: 0.0, green: 0.85, blue: 1.0).opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
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

    private var protocolColor: Color {
        switch server.proto {
        case .wireguard: return Color(red: 0.0, green: 0.75, blue: 0.5)
        case .amneziawg: return Color(red: 0.0, green: 0.6, blue: 0.8)
        case .vless: return Color(red: 0.3, green: 0.5, blue: 1.0)
        case .vmess: return Color(red: 0.6, green: 0.4, blue: 1.0)
        case .trojan: return Color(red: 0.9, green: 0.3, blue: 0.4)
        case .shadowsocks: return Color(red: 0.2, green: 0.7, blue: 0.9)
        case .hysteria2: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .socks5, .http: return .white.opacity(0.5)
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms < 100 { return Color(red: 0.0, green: 0.85, blue: 0.5) }
        if ms < 300 { return Color(red: 1.0, green: 0.8, blue: 0.2) }
        return Color(red: 0.9, green: 0.3, blue: 0.3)
    }
}
