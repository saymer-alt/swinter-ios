import SwiftUI

struct ServerEditView: View {
    @Environment(\.dismiss) var dismiss

    let initialServer: Server?
    let onSave: (Server) -> Void

    @State private var name: String
    @State private var address: String
    @State private var proto: ProxyProtocol
    @State private var turnEnabled: Bool
    @State private var turnSource: TurnOverlaySource

    // WireGuard
    @State private var wgPrivateKey: String
    @State private var wgPublicKey: String
    @State private var wgAddress: String
    @State private var wgDNS: String
    @State private var wgMTU: String

    // VLESS
    @State private var vlessUUID: String
    @State private var vlessFlow: String
    @State private var vlessTransport: ProxyTransport
    @State private var vlessTLS: TLSMode
    @State private var vlessSNI: String
    @State private var vlessFingerprint: String
    @State private var vlessRealityPubKey: String
    @State private var vlessRealityShortId: String
    @State private var vlessWSPath: String

    // VMess
    @State private var vmessUUID: String
    @State private var vmessSecurity: String
    @State private var vmessTransport: ProxyTransport
    @State private var vmessTLS: TLSMode
    @State private var vmessSNI: String
    @State private var vmessWSPath: String

    // Trojan
    @State private var trojanPassword: String
    @State private var trojanTransport: ProxyTransport
    @State private var trojanSNI: String

    // Shadowsocks
    @State private var ssMethod: String
    @State private var ssPassword: String

    // Hysteria2
    @State private var hy2Password: String
    @State private var hy2Obfs: String
    @State private var hy2ObfsPassword: String
    @State private var hy2SNI: String

    // TURN overlay
    @State private var turnVKLink: String
    @State private var turnMaxToken: String
    @State private var turnMaxUserID: String
    @State private var turnUseUDP: Bool
    @State private var turnNumConns: String

    init(server: Server?, onSave: @escaping (Server) -> Void) {
        self.initialServer = server
        self.onSave = onSave

        let s = server ?? Server()
        _name = State(initialValue: s.name)
        _address = State(initialValue: s.address)
        _proto = State(initialValue: s.proto)

        // TURN
        _turnEnabled = State(initialValue: s.turnOverlay != nil)
        let turn = s.turnOverlay ?? TurnOverlayConfig()
        _turnSource = State(initialValue: turn.source)
        _turnVKLink = State(initialValue: turn.vkLink)
        _turnMaxToken = State(initialValue: turn.maxToken)
        _turnMaxUserID = State(initialValue: turn.maxTargetUserID)
        _turnUseUDP = State(initialValue: turn.useUDP)
        _turnNumConns = State(initialValue: "\(turn.numConns)")

        // WireGuard
        let wg: WireGuardConfig
        if case .wireguard(let c) = s.protocolConfig { wg = c } else { wg = WireGuardConfig() }
        _wgPrivateKey = State(initialValue: wg.privateKey)
        _wgPublicKey = State(initialValue: wg.publicKey)
        _wgAddress = State(initialValue: wg.wgAddress)
        _wgDNS = State(initialValue: wg.dns)
        _wgMTU = State(initialValue: "\(wg.mtu)")

        // VLESS
        let vl: VLESSConfig
        if case .vless(let c) = s.protocolConfig { vl = c } else { vl = VLESSConfig() }
        _vlessUUID = State(initialValue: vl.uuid)
        _vlessFlow = State(initialValue: vl.flow)
        _vlessTransport = State(initialValue: vl.transport)
        _vlessTLS = State(initialValue: vl.tls)
        _vlessSNI = State(initialValue: vl.sni)
        _vlessFingerprint = State(initialValue: vl.fingerprint)
        _vlessRealityPubKey = State(initialValue: vl.realityPublicKey)
        _vlessRealityShortId = State(initialValue: vl.realityShortId)
        _vlessWSPath = State(initialValue: vl.wsPath)

        // VMess
        let vm: VMessConfig
        if case .vmess(let c) = s.protocolConfig { vm = c } else { vm = VMessConfig() }
        _vmessUUID = State(initialValue: vm.uuid)
        _vmessSecurity = State(initialValue: vm.security)
        _vmessTransport = State(initialValue: vm.transport)
        _vmessTLS = State(initialValue: vm.tls)
        _vmessSNI = State(initialValue: vm.sni)
        _vmessWSPath = State(initialValue: vm.wsPath)

        // Trojan
        let tr: TrojanConfig
        if case .trojan(let c) = s.protocolConfig { tr = c } else { tr = TrojanConfig() }
        _trojanPassword = State(initialValue: tr.password)
        _trojanTransport = State(initialValue: tr.transport)
        _trojanSNI = State(initialValue: tr.sni)

        // Shadowsocks
        let ss: ShadowsocksConfig
        if case .shadowsocks(let c) = s.protocolConfig { ss = c } else { ss = ShadowsocksConfig() }
        _ssMethod = State(initialValue: ss.method)
        _ssPassword = State(initialValue: ss.password)

        // Hysteria2
        let hy: Hysteria2Config
        if case .hysteria2(let c) = s.protocolConfig { hy = c } else { hy = Hysteria2Config() }
        _hy2Password = State(initialValue: hy.password)
        _hy2Obfs = State(initialValue: hy.obfs)
        _hy2ObfsPassword = State(initialValue: hy.obfsPassword)
        _hy2SNI = State(initialValue: hy.sni)
    }

    var body: some View {
        NavigationView {
            Form {
                // Basic info
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Address (host:port)", text: $address)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    Picker("Protocol", selection: $proto) {
                        ForEach(ProxyProtocol.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                }

                // Protocol-specific fields
                switch proto {
                case .wireguard: wireGuardSection
                case .amneziawg: amneziaWGSection
                case .vless: vlessSection
                case .vmess: vmessSection
                case .trojan: trojanSection
                case .shadowsocks: shadowsocksSection
                case .hysteria2: hysteria2Section
                case .socks5, .http: EmptyView()
                }

                // TURN overlay (WireGuard only)
                if proto.supportsTURN {
                    turnSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.1))
            .navigationTitle(initialServer == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(address.isEmpty)
                }
            }
        }
    }

    // MARK: - WireGuard

    private var wireGuardSection: some View {
        Section("WireGuard") {
            SecureField("Private Key", text: $wgPrivateKey)
                .autocapitalization(.none)
            TextField("Server Public Key", text: $wgPublicKey)
                .autocapitalization(.none)
            TextField("WG Address", text: $wgAddress)
                .autocapitalization(.none)
            TextField("DNS", text: $wgDNS)
                .keyboardType(.decimalPad)
            TextField("MTU", text: $wgMTU)
                .keyboardType(.numberPad)
        }
    }

    // MARK: - AmneziaWG

    @State private var awgPrivateKey: String = ""
    @State private var awgPublicKey: String = ""
    @State private var awgPresharedKey: String = ""
    @State private var awgAddress: String = "10.8.0.2/24"
    @State private var awgDNS: String = "1.1.1.1"
    @State private var awgJc: String = "4"
    @State private var awgJmin: String = "40"
    @State private var awgJmax: String = "70"
    @State private var awgS1: String = "0"
    @State private var awgS2: String = "0"
    @State private var awgH1: String = "1"
    @State private var awgH2: String = "2"
    @State private var awgH3: String = "3"
    @State private var awgH4: String = "4"

    private var amneziaWGSection: some View {
        Group {
            Section("AmneziaWG") {
                SecureField("Private Key", text: $awgPrivateKey)
                    .autocapitalization(.none)
                TextField("Server Public Key", text: $awgPublicKey)
                    .autocapitalization(.none)
                TextField("Preshared Key (optional)", text: $awgPresharedKey)
                    .autocapitalization(.none)
                TextField("Address", text: $awgAddress)
                    .autocapitalization(.none)
                TextField("DNS", text: $awgDNS)
                    .keyboardType(.decimalPad)
            }
            Section("Obfuscation") {
                HStack {
                    VStack(alignment: .leading) { Text("Jc").font(.caption); TextField("4", text: $awgJc).keyboardType(.numberPad) }
                    VStack(alignment: .leading) { Text("Jmin").font(.caption); TextField("40", text: $awgJmin).keyboardType(.numberPad) }
                    VStack(alignment: .leading) { Text("Jmax").font(.caption); TextField("70", text: $awgJmax).keyboardType(.numberPad) }
                }
                HStack {
                    VStack(alignment: .leading) { Text("S1").font(.caption); TextField("0", text: $awgS1).keyboardType(.numberPad) }
                    VStack(alignment: .leading) { Text("S2").font(.caption); TextField("0", text: $awgS2).keyboardType(.numberPad) }
                }
                HStack {
                    VStack(alignment: .leading) { Text("H1").font(.caption); TextField("1", text: $awgH1).keyboardType(.numberPad) }
                    VStack(alignment: .leading) { Text("H2").font(.caption); TextField("2", text: $awgH2).keyboardType(.numberPad) }
                }
                HStack {
                    VStack(alignment: .leading) { Text("H3").font(.caption); TextField("3", text: $awgH3).keyboardType(.numberPad) }
                    VStack(alignment: .leading) { Text("H4").font(.caption); TextField("4", text: $awgH4).keyboardType(.numberPad) }
                }
            }
        }
    }

    // MARK: - VLESS

    private var vlessSection: some View {
        Group {
            Section("VLESS") {
                TextField("UUID", text: $vlessUUID)
                    .autocapitalization(.none)
                TextField("Flow (e.g. xtls-rprx-vision)", text: $vlessFlow)
                    .autocapitalization(.none)
                Picker("Transport", selection: $vlessTransport) {
                    ForEach(ProxyTransport.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
            }

            Section("TLS") {
                Picker("TLS", selection: $vlessTLS) {
                    ForEach(TLSMode.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                if vlessTLS != .none {
                    TextField("SNI", text: $vlessSNI)
                        .autocapitalization(.none)
                    TextField("Fingerprint", text: $vlessFingerprint)
                        .autocapitalization(.none)
                }
                if vlessTLS == .reality {
                    TextField("Reality Public Key", text: $vlessRealityPubKey)
                        .autocapitalization(.none)
                    TextField("Reality Short ID", text: $vlessRealityShortId)
                        .autocapitalization(.none)
                }
            }

            if vlessTransport == .ws {
                Section("WebSocket") {
                    TextField("Path", text: $vlessWSPath)
                        .autocapitalization(.none)
                }
            }
        }
    }

    // MARK: - VMess

    private var vmessSection: some View {
        Group {
            Section("VMess") {
                TextField("UUID", text: $vmessUUID)
                    .autocapitalization(.none)
                TextField("Security (auto)", text: $vmessSecurity)
                    .autocapitalization(.none)
                Picker("Transport", selection: $vmessTransport) {
                    ForEach(ProxyTransport.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                Picker("TLS", selection: $vmessTLS) {
                    ForEach([TLSMode.none, TLSMode.tls], id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                if vmessTLS == .tls {
                    TextField("SNI", text: $vmessSNI)
                        .autocapitalization(.none)
                }
            }
        }
    }

    // MARK: - Trojan

    private var trojanSection: some View {
        Section("Trojan") {
            SecureField("Password", text: $trojanPassword)
            TextField("SNI", text: $trojanSNI)
                .autocapitalization(.none)
            Picker("Transport", selection: $trojanTransport) {
                ForEach([ProxyTransport.tcp, ProxyTransport.ws], id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
        }
    }

    // MARK: - Shadowsocks

    private var shadowsocksSection: some View {
        Section("Shadowsocks") {
            Picker("Method", selection: $ssMethod) {
                Text("aes-256-gcm").tag("aes-256-gcm")
                Text("chacha20-ietf-poly1305").tag("chacha20-ietf-poly1305")
                Text("2022-blake3-aes-256-gcm").tag("2022-blake3-aes-256-gcm")
                Text("2022-blake3-chacha20-poly1305").tag("2022-blake3-chacha20-poly1305")
            }
            SecureField("Password", text: $ssPassword)
        }
    }

    // MARK: - Hysteria2

    private var hysteria2Section: some View {
        Section("Hysteria2") {
            SecureField("Password", text: $hy2Password)
            TextField("SNI", text: $hy2SNI)
                .autocapitalization(.none)
            TextField("Obfs Type (e.g. salamander)", text: $hy2Obfs)
                .autocapitalization(.none)
            if !hy2Obfs.isEmpty {
                SecureField("Obfs Password", text: $hy2ObfsPassword)
            }
        }
    }

    // MARK: - TURN Overlay

    @State private var showMaxLogin = false

    private var turnSection: some View {
        Section("TURN Overlay") {
            Toggle("Enable TURN", isOn: $turnEnabled)

            if turnEnabled {
                Picker("Source", selection: $turnSource) {
                    Text("MAX TURN").tag(TurnOverlaySource.max)
                    Text("VK TURN").tag(TurnOverlaySource.vk)
                }

                if turnSource == .vk {
                    TextField("VK Call Link", text: $turnVKLink)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    Text("Создай звонок на vk.com/call и вставь ссылку")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // MAX TURN — show login status
                    if MaxAuthService.shared.isLoggedIn {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("MAX: \(MaxAuthService.shared.maskedPhone)")
                                .font(.system(size: 14))
                            Spacer()
                            Button("Выйти") {
                                MaxAuthService.shared.logout()
                                turnMaxToken = ""
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            showMaxLogin = true
                        } label: {
                            HStack {
                                Image(systemName: "phone.fill")
                                Text("Войти в MAX")
                            }
                        }
                    }

                    TextField("Target User ID", text: $turnMaxUserID)
                        .keyboardType(.numberPad)

                    Toggle("UDP", isOn: $turnUseUDP)
                    TextField("Connections", text: $turnNumConns)
                        .keyboardType(.numberPad)
                }
            }
        }
        .sheet(isPresented: $showMaxLogin) {
            MaxLoginView()
        }
        .onChange(of: showMaxLogin) { showing in
            if !showing {
                // Refresh token after login
                if let token = UserDefaults(suiteName: "group.com.swinter.vpn")?.string(forKey: MaxAuthService.tokenKey) {
                    turnMaxToken = token
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        var server = initialServer ?? Server(proto: proto)
        server.name = name
        server.address = address
        server.proto = proto

        switch proto {
        case .wireguard:
            server.protocolConfig = .wireguard(WireGuardConfig(
                privateKey: wgPrivateKey,
                publicKey: wgPublicKey,
                peerAddress: address,
                wgAddress: wgAddress,
                dns: wgDNS,
                mtu: Int(wgMTU) ?? 1280
            ))
        case .amneziawg:
            server.protocolConfig = .amneziawg(AmneziaWGConfig(
                privateKey: awgPrivateKey,
                publicKey: awgPublicKey,
                presharedKey: awgPresharedKey,
                peerAddress: address,
                wgAddress: awgAddress,
                dns: awgDNS,
                jc: Int(awgJc) ?? 4,
                jmin: Int(awgJmin) ?? 40,
                jmax: Int(awgJmax) ?? 70,
                s1: Int(awgS1) ?? 0,
                s2: Int(awgS2) ?? 0,
                h1: Int(awgH1) ?? 1,
                h2: Int(awgH2) ?? 2,
                h3: Int(awgH3) ?? 3,
                h4: Int(awgH4) ?? 4
            ))
        case .vless:
            server.protocolConfig = .vless(VLESSConfig(
                uuid: vlessUUID, flow: vlessFlow,
                transport: vlessTransport, tls: vlessTLS,
                sni: vlessSNI, fingerprint: vlessFingerprint,
                realityPublicKey: vlessRealityPubKey, realityShortId: vlessRealityShortId,
                wsPath: vlessWSPath
            ))
        case .vmess:
            server.protocolConfig = .vmess(VMessConfig(
                uuid: vmessUUID, security: vmessSecurity,
                transport: vmessTransport, tls: vmessTLS,
                sni: vmessSNI, wsPath: vmessWSPath
            ))
        case .trojan:
            server.protocolConfig = .trojan(TrojanConfig(
                password: trojanPassword, transport: trojanTransport,
                sni: trojanSNI
            ))
        case .shadowsocks:
            server.protocolConfig = .shadowsocks(ShadowsocksConfig(method: ssMethod, password: ssPassword))
        case .hysteria2:
            server.protocolConfig = .hysteria2(Hysteria2Config(
                password: hy2Password, obfs: hy2Obfs, obfsPassword: hy2ObfsPassword, sni: hy2SNI
            ))
        case .socks5:
            server.protocolConfig = .socks5(Socks5Config())
        case .http:
            server.protocolConfig = .http(HTTPProxyConfig())
        }

        if turnEnabled && proto.supportsTURN {
            // For MAX: auto-fill token from MaxAuthService if empty
            let effectiveToken: String
            if turnSource == .max {
                effectiveToken = turnMaxToken.isEmpty
                    ? (UserDefaults(suiteName: "group.com.swinter.vpn")?.string(forKey: MaxAuthService.tokenKey) ?? "")
                    : turnMaxToken
            } else {
                effectiveToken = turnMaxToken
            }

            server.turnOverlay = TurnOverlayConfig(
                source: turnSource,
                vkLink: turnVKLink,
                maxToken: effectiveToken,
                maxTargetUserID: turnMaxUserID,
                useUDP: turnUseUDP,
                numConns: Int(turnNumConns) ?? 4
            )
        } else {
            server.turnOverlay = nil
        }

        onSave(server)
        dismiss()
    }
}
