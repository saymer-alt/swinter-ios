import Foundation
import NetworkExtension
import Network
import Combine
import WidgetKit
import Swinterlib

@MainActor
class VPNManager: ObservableObject {
    @Published var state: VPNState = .disconnected
    @Published var config: VPNConfig = VPNConfig.load()
    @Published var appConfig: AppConfig = AppConfig.load()
    @Published var uploadSpeed: String = "0 KB/s"
    @Published var downloadSpeed: String = "0 KB/s"
    @Published var lastError: String = ""
    @Published var connectingStatus: String = ""

    private var vpnManager: NETunnelProviderManager?
    private var statusObserver: Any?
    private var maxCallStatusTimer: Timer?

    // Auto-reconnect state
    private var userInitiatedDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 10
    private var wasConnected = false
    private var pathMonitor: NWPathMonitor?
    private var networkAvailable = true
    private var statsTimer: Timer?
    private var lastStats = NetworkStats()
    @Published var totalBytesIn: UInt64 = 0
    @Published var totalBytesOut: UInt64 = 0

    init() {
        // iCloud sync
        if appConfig.settings.iCloudSyncEnabled {
            appConfig = CloudSync.shared.sync(local: appConfig)
            appConfig.save()
            CloudSync.shared.startObserving { [weak self] cloudConfig in
                Task { @MainActor in
                    self?.appConfig = cloudConfig
                    self?.appConfig.save()
                }
            }
        }

        Task {
            await loadManager()
            startNetworkMonitor()
            refreshAllSubscriptions()
            refreshConfig() // auto-update routing config
        }
    }

    // MARK: - Load existing VPN manager

    func loadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first {
                vpnManager = existing
            } else {
                vpnManager = NETunnelProviderManager()
            }
            observeStatus()
            updateState()
        } catch {
            print("[VPNManager] Failed to load: \(error)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Network Monitor (for auto-reconnect)

    private func startNetworkMonitor() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                let available = path.status == .satisfied
                let wasUnavailable = !self.networkAvailable
                self.networkAvailable = available

                if available && wasUnavailable && self.wasConnected && !self.userInitiatedDisconnect {
                    print("[VPNManager] Network restored, triggering reconnect")
                    self.scheduleReconnect()
                }
            }
        }
        pathMonitor?.start(queue: DispatchQueue.global(qos: .utility))
    }

    // MARK: - VPN Detection

    /// Check if another VPN (not ours) is currently active
    func checkOtherVPNActive() async -> Bool {
        // Check system VPN (IKEv2, IPSec, etc.)
        let systemVPN = NEVPNManager.shared()
        do {
            try await systemVPN.loadFromPreferences()
            if systemVPN.connection.status == .connected {
                return true
            }
        } catch {}

        // Check other tunnel provider apps
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            for mgr in managers {
                if mgr !== vpnManager && mgr.connection.status == .connected {
                    return true
                }
            }
        } catch {}

        return false
    }

    // MARK: - Auto-Reconnect

    private func scheduleReconnect() {
        guard state == .disconnected,
              !userInitiatedDisconnect,
              wasConnected,
              reconnectAttempt < maxReconnectAttempts else { return }

        reconnectTask?.cancel()
        reconnectTask = Task {
            let delay = min(Double(2 << reconnectAttempt), 60.0) // 2, 4, 8, 16, 32, 60...
            reconnectAttempt += 1

            await MainActor.run {
                self.connectingStatus = "Переподключение (\(self.reconnectAttempt)/\(self.maxReconnectAttempts)) через \(Int(delay))с..."
                self.state = .connecting
            }

            print("[VPNManager] Auto-reconnect #\(reconnectAttempt) in \(delay)s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled else { return }
            guard self.networkAvailable else {
                await MainActor.run {
                    self.connectingStatus = "Ожидание сети..."
                    self.state = .connecting
                }
                return
            }

            await MainActor.run {
                self.connect()
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
    }

    // MARK: - Connect

    func connect() {
        guard state == .disconnected || (state == .connecting && reconnectTask != nil) else {
            print("[VPNManager] connect() ignored: state=\(state)")
            return
        }
        state = .connecting
        lastError = ""
        connectingStatus = "Подготовка..."
        userInitiatedDisconnect = false

        // New path: use active server from AppConfig
        if let server = appConfig.activeServer, !server.address.isEmpty {
            print("[VPNManager] Connecting to \(server.name.isEmpty ? server.address : server.name) (\(server.proto.displayName)) turn=\(server.turnOverlay != nil)")
            connectServer(server)
            return
        }

        // Legacy fallback: use old VPNConfig
        let savedConfig = config
        if savedConfig.turnSource == .maxCall {
            connectMaxCall(config: savedConfig)
            return
        }
        connectLegacy(savedConfig)
    }

    // MARK: - Connect via Server model

    private func connectServer(_ server: Server) {
        Task {
            do {
                if await checkOtherVPNActive() {
                    await MainActor.run {
                        self.lastError = "Другой VPN активен — отключите его"
                        self.state = .disconnected
                        self.connectingStatus = ""
                    }
                    return
                }

                var resolvedTurnIPs: [String] = []
                var resolvedAPIIPs: [String] = []
                var turnUser = ""
                var turnPass = ""
                var turnAddr = ""

                // Resolve TURN credentials if server has TURN overlay
                if let turn = server.turnOverlay {
                    let sourceLabel = turn.source == .vk ? "VK" : "MAX"

                    // Always get token from MaxAuthService (most reliable source)
                    let savedMaxToken = UserDefaults(suiteName: "group.com.swinter.vpn")?.string(forKey: MaxAuthService.tokenKey) ?? ""
                    let effectiveToken = savedMaxToken.isEmpty ? turn.maxToken : savedMaxToken
                    let defaultTargetID = self.appConfig.settings.defaultTurnTargetUserID
                    let effectiveTargetID = turn.maxTargetUserID.isEmpty ? defaultTargetID : turn.maxTargetUserID

                    // Try cached TURN credentials first (saves a "call" to target user)
                    let cached = self.loadCachedTURNCreds()
                    if let cached = cached {
                        print("[VPNManager] Using cached TURN creds (age: \(Int(-cached.cachedAt.timeIntervalSinceNow))s)")
                        turnUser = cached.turnUser
                        turnPass = cached.turnPass
                        turnAddr = cached.turnAddr
                        resolvedTurnIPs = cached.turnIPs
                    }

                    if turn.source == .max && effectiveToken.isEmpty {
                        await MainActor.run {
                            self.lastError = "MAX не авторизован. Войдите в MAX в Settings."
                            self.state = .disconnected
                            self.connectingStatus = ""
                        }
                        return
                    }

                    if turn.source == .max && effectiveTargetID.isEmpty {
                        await MainActor.run {
                            self.lastError = "Не указан Target User ID. Укажите в Settings → TURN TARGET."
                            self.state = .disconnected
                            self.connectingStatus = ""
                        }
                        return
                    }

                    // Only resolve fresh if no cached creds
                    if turnUser.isEmpty {
                    for attempt in 1...5 {
                        await MainActor.run { self.connectingStatus = "\(sourceLabel): TURN-креды (\(attempt)/5)..." }

                        let result: (String, NSError?) = await withCheckedContinuation { cont in
                            DispatchQueue.global(qos: .userInitiated).async {
                                var err: NSError?
                                let res: String
                                switch turn.source {
                                case .vk:
                                    res = VpnlibResolveConfig(turn.vkLink, &err)
                                case .max:
                                    let maxUserID = Int64(effectiveTargetID) ?? 0
                                    res = VpnlibResolveConfigMAX(effectiveToken, maxUserID, &err)
                                }
                                cont.resume(returning: (res, err))
                            }
                        }

                        if let err = result.1 {
                            print("[VPNManager] TURN attempt \(attempt) failed: \(err)")
                            if attempt < 5 { try await Task.sleep(nanoseconds: 1_500_000_000) }
                            continue
                        }

                        if let data = result.0.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            resolvedTurnIPs = json["turnIPs"] as? [String] ?? []
                            resolvedAPIIPs = json["apiIPs"] as? [String] ?? []
                            turnUser = json["turnUser"] as? String ?? ""
                            turnPass = json["turnPass"] as? String ?? ""
                            turnAddr = json["turnAddr"] as? String ?? ""
                            break
                        }
                    }

                    // Cache fresh credentials
                    if !turnUser.isEmpty {
                        self.saveCachedTURNCreds(turnUser: turnUser, turnPass: turnPass, turnAddr: turnAddr, turnIPs: resolvedTurnIPs)
                    }
                    } // end if turnUser.isEmpty (only resolve if no cache)

                    if turnUser.isEmpty {
                        await MainActor.run {
                            self.lastError = "TURN credentials не получены"
                            self.state = .disconnected
                            self.connectingStatus = ""
                        }
                        return
                    }
                }

                await MainActor.run { self.connectingStatus = "Запускаем туннель..." }

                // Build config JSON for Go library
                let goConfig = buildGoConfig(server: server, turnUser: turnUser, turnPass: turnPass, turnAddr: turnAddr)

                let manager = vpnManager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = "com.swinter.vpn.tunnel"
                proto.serverAddress = server.address

                proto.providerConfiguration = [
                    "config": goConfig,
                    "turnIPs": resolvedTurnIPs.joined(separator: ","),
                    "apiIPs": resolvedAPIIPs.joined(separator: ","),
                ]

                manager.protocolConfiguration = proto
                manager.localizedDescription = "Swinter"
                manager.isEnabled = true

                // On-Demand rules
                self.applyOnDemandRules(to: manager)

                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()

                await MainActor.run {
                    self.vpnManager = manager
                    self.observeStatus()
                }

                let session = manager.connection as! NETunnelProviderSession
                try session.startTunnel(options: nil)
                print("[VPNManager] Tunnel start requested for \(server.proto.displayName)")

            } catch {
                print("[VPNManager] Connect error: \(error)")
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.state = .disconnected
                    self.connectingStatus = ""
                }
            }
        }
    }

    // MARK: - Build Go config from Server

    private func buildGoConfig(server: Server, turnUser: String, turnPass: String, turnAddr: String) -> String {
        // WireGuard (with or without TURN) — legacy format for Go library
        if case .wireguard(let wg) = server.protocolConfig {
            var dict: [String: Any] = [
                "peerAddr": wg.peerAddress.isEmpty ? server.address : wg.peerAddress,
                "wgPrivateKey": wg.privateKey,
                "wgPublicKey": wg.publicKey,
                "wgPresharedKey": wg.presharedKey,
                "wgAddress": wg.wgAddress,
                "wgDNS": wg.dns,
                "mtu": wg.mtu,
            ]
            if server.turnOverlay != nil {
                dict["turnUser"] = turnUser
                dict["turnPass"] = turnPass
                dict["turnAddr"] = turnAddr
                dict["useUDP"] = server.turnOverlay?.useUDP ?? false
                dict["numConns"] = server.turnOverlay?.numConns ?? 16
            }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }

        // AmneziaWG (with or without TURN) — legacy WG format + AWG params
        if case .amneziawg(let awg) = server.protocolConfig {
            var dict: [String: Any] = [
                "peerAddr": awg.peerAddress.isEmpty ? server.address : awg.peerAddress,
                "wgPrivateKey": awg.privateKey,
                "wgPublicKey": awg.publicKey,
                "wgPresharedKey": awg.presharedKey,
                "wgAddress": awg.wgAddress,
                "wgDNS": awg.dns,
                "mtu": awg.mtu,
                "protocol": "amneziawg",
                "jc": awg.jc,
                "jmin": awg.jmin,
                "jmax": awg.jmax,
                "s1": awg.s1,
                "s2": awg.s2,
                "h1": awg.h1,
                "h2": awg.h2,
                "h3": awg.h3,
                "h4": awg.h4,
            ]
            if server.turnOverlay != nil {
                dict["turnUser"] = turnUser
                dict["turnPass"] = turnPass
                dict["turnAddr"] = turnAddr
                dict["useUDP"] = server.turnOverlay?.useUDP ?? false
                dict["numConns"] = server.turnOverlay?.numConns ?? 16
            }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }

        // For all other protocols — new ServerConfig format
        var dict: [String: Any] = [
            "protocol": server.proto.rawValue,
            "address": server.address,
        ]

        switch server.protocolConfig {
        case .wireguard, .amneziawg:
            break // handled above
        case .vless(let v):
            dict["vless"] = [
                "uuid": v.uuid,
                "flow": v.flow,
                "transport": v.transport.rawValue,
                "tls": v.tls.rawValue,
                "sni": v.sni,
                "fingerprint": v.fingerprint,
                "realityPublicKey": v.realityPublicKey,
                "realityShortId": v.realityShortId,
                "wsPath": v.wsPath,
            ]
        case .vmess(let v):
            dict["vmess"] = [
                "uuid": v.uuid,
                "alterId": v.alterId,
                "security": v.security,
                "transport": v.transport.rawValue,
                "tls": v.tls.rawValue,
                "sni": v.sni,
                "wsPath": v.wsPath,
            ]
        case .trojan(let t):
            dict["trojan"] = [
                "password": t.password,
                "transport": t.transport.rawValue,
                "tls": t.tls.rawValue,
                "sni": t.sni,
            ]
        case .shadowsocks(let ss):
            dict["shadowsocks"] = [
                "method": ss.method,
                "password": ss.password,
            ]
        case .hysteria2(let h):
            dict["hysteria2"] = [
                "password": h.password,
                "obfs": h.obfs,
                "obfsPassword": h.obfsPassword,
                "uploadMbps": h.uploadMbps,
                "downloadMbps": h.downloadMbps,
                "sni": h.sni,
            ]
        case .socks5(let s):
            dict["socks5"] = [
                "username": s.username,
                "password": s.password,
                "tls": s.tls,
            ]
        case .http(let h):
            dict["http"] = [
                "username": h.username,
                "password": h.password,
                "tls": h.tls,
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    // MARK: - Legacy connect (backward compat with old VPNConfig)

    private func connectLegacy(_ savedConfig: VPNConfig) {
        let vkLink = savedConfig.vkLink

        Task {
            do {
                if await checkOtherVPNActive() {
                    await MainActor.run {
                        self.lastError = "Другой VPN активен — отключите его"
                        self.state = .disconnected
                        self.connectingStatus = ""
                    }
                    return
                }

                var resolvedTurnIPs: [String] = []
                var resolvedAPIIPs: [String] = []
                var turnUser = ""
                var turnPass = ""
                var turnAddr = ""
                var lastResolveError = ""
                let source = savedConfig.turnSource

                for attempt in 1...5 {
                    let sourceLabel = source == .vk ? "VK" : "MAX"
                    await MainActor.run { self.connectingStatus = "\(sourceLabel): TURN-креды (\(attempt)/5)..." }

                    let result: (String, NSError?) = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            var err: NSError?
                            let res: String
                            switch source {
                            case .vk:
                                res = VpnlibResolveConfig(vkLink, &err)
                            case .max:
                                let maxToken = UserDefaults(suiteName: "group.com.swinter.vpn")?.string(forKey: MaxAuthService.tokenKey) ?? savedConfig.maxToken
                                let maxUserID = Int64(savedConfig.maxTargetUserID) ?? 0
                                res = VpnlibResolveConfigMAX(maxToken, maxUserID, &err)
                            case .maxCall:
                                fatalError("maxCall handled separately")
                            }
                            cont.resume(returning: (res, err))
                        }
                    }

                    if let err = result.1 {
                        lastResolveError = err.localizedDescription
                        if attempt < 5 { try await Task.sleep(nanoseconds: 1_500_000_000) }
                        continue
                    }

                    if let data = result.0.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        resolvedTurnIPs = json["turnIPs"] as? [String] ?? []
                        resolvedAPIIPs = json["apiIPs"] as? [String] ?? []
                        turnUser = json["turnUser"] as? String ?? ""
                        turnPass = json["turnPass"] as? String ?? ""
                        turnAddr = json["turnAddr"] as? String ?? ""
                        break
                    }
                }

                if turnUser.isEmpty {
                    await MainActor.run {
                        self.lastError = "TURN (5 попыток): \(lastResolveError)"
                        self.state = .disconnected
                        self.connectingStatus = ""
                    }
                    return
                }

                var enrichedConfig = savedConfig
                enrichedConfig.turnUser = turnUser
                enrichedConfig.turnPass = turnPass
                enrichedConfig.turnAddr = turnAddr

                let manager = vpnManager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = "com.swinter.vpn.tunnel"
                proto.serverAddress = savedConfig.peerAddr

                proto.providerConfiguration = [
                    "config": enrichedConfig.toJSON(),
                    "turnIPs": resolvedTurnIPs.joined(separator: ","),
                    "apiIPs": resolvedAPIIPs.joined(separator: ","),
                ]

                manager.protocolConfiguration = proto
                manager.localizedDescription = "Swinter"
                manager.isEnabled = true
                self.applyOnDemandRules(to: manager)

                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()

                await MainActor.run {
                    self.vpnManager = manager
                    self.observeStatus()
                }

                let session = manager.connection as! NETunnelProviderSession
                try session.startTunnel(options: nil)

            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.state = .disconnected
                    self.connectingStatus = ""
                }
            }
        }
    }

    // MARK: - MAX Call Status Polling

    private func startMaxCallStatusPolling() {
        maxCallStatusTimer?.invalidate()
        maxCallStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateState()
            }
        }
    }

    private func stopMaxCallStatusPolling() {
        maxCallStatusTimer?.invalidate()
        maxCallStatusTimer = nil
    }

    // MARK: - Swinter (no Network Extension, runs in-app)

    private func connectMaxCall(config: VPNConfig) {
        Task {
            do {
                // Check if another VPN is active
                if await checkOtherVPNActive() {
                    await MainActor.run {
                        self.lastError = "Другой VPN активен — отключите его, иначе MAX/VK серверы будут недоступны"
                        self.state = .disconnected
                        self.connectingStatus = ""
                    }
                    return
                }

                await MainActor.run { self.connectingStatus = "MAX Call: подключение..." }

                let manager = vpnManager ?? NETunnelProviderManager()

                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = "com.swinter.vpn.tunnel"
                proto.serverAddress = "Swinter"

                // Pass MAX Call config to tunnel extension
                let maxCallConfig: [String: Any] = [
                    "mode": "maxCall",
                    "maxToken": config.maxToken,
                    "maxTargetUserID": config.maxTargetUserID,
                    "maxCallServerPubkey": config.maxCallServerPubkey,
                    "deviceId": UUID().uuidString,
                ]
                let configData = try JSONSerialization.data(withJSONObject: maxCallConfig)
                let configStr = String(data: configData, encoding: .utf8)!

                proto.providerConfiguration = [
                    "config": configStr,
                    "mode": "maxCall",
                ]

                manager.protocolConfiguration = proto
                manager.localizedDescription = "Swinter"
                manager.isEnabled = true
                self.applyOnDemandRules(to: manager)

                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()

                await MainActor.run {
                    self.vpnManager = manager
                    self.observeStatus()
                }

                let session = manager.connection as! NETunnelProviderSession
                try session.startTunnel(options: nil)

                print("[VPNManager] MAX Call tunnel start requested")
                await MainActor.run { self.startMaxCallStatusPolling() }

            } catch {
                print("[VPNManager] MAX Call error: \(error)")
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.state = .disconnected
                    self.connectingStatus = ""
                }
            }
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        guard state == .connected || state == .connecting else { return }
        print("[VPNManager] ⏹ Manual disconnect by user")
        userInitiatedDisconnect = true
        cancelReconnect()
        state = .disconnecting
        stopMaxCallStatusPolling()
        // Clear MAX Call status
        UserDefaults(suiteName: "group.com.swinter.vpn")?.removeObject(forKey: "maxcall_status")
        vpnManager?.connection.stopVPNTunnel()
    }

    // MARK: - Server Management

    func addServer(_ server: Server) {
        appConfig.addServer(server)
        appConfig.save()
    }

    func removeServer(_ id: UUID) {
        appConfig.removeServer(id: id)
        appConfig.save()
    }

    func updateServer(_ server: Server) {
        if let idx = appConfig.servers.firstIndex(where: { $0.id == server.id }) {
            appConfig.servers[idx] = server
            appConfig.save()
        }
    }

    func setActiveServer(_ id: UUID) {
        let wasConnected = state == .connected || state == .connecting
        let oldID = appConfig.activeServerID
        appConfig.activeServerID = id
        appConfig.save()

        // If switching server while connected — disconnect first, then reconnect
        if wasConnected && oldID != id {
            print("[VPNManager] Server switched while connected, reconnecting...")
            disconnect()
            // Reconnect after short delay
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    self.userInitiatedDisconnect = false
                    self.connect()
                }
            }
        }
    }

    func toggleFavorite(_ id: UUID) {
        if let idx = appConfig.servers.firstIndex(where: { $0.id == id }) {
            appConfig.servers[idx].isFavorite.toggle()
            appConfig.save()
        }
    }

    func updateServerLatency(_ id: UUID, latencyMs: Int) {
        if let idx = appConfig.servers.firstIndex(where: { $0.id == id }) {
            appConfig.servers[idx].latencyMs = latencyMs
        }
    }

    // MARK: - Group Management

    func addGroup(_ group: ProxyGroup) {
        appConfig.groups.append(group)
        appConfig.save()
    }

    func updateGroup(_ group: ProxyGroup) {
        if let idx = appConfig.groups.firstIndex(where: { $0.id == group.id }) {
            appConfig.groups[idx] = group
            appConfig.save()
        }
    }

    func removeGroup(_ id: UUID) {
        appConfig.groups.removeAll { $0.id == id }
        appConfig.save()
    }

    // MARK: - Scene Management

    func addScene(_ scene: VPNScene) {
        appConfig.scenes.append(scene)
        appConfig.save()
    }

    func updateScene(_ scene: VPNScene) {
        if let idx = appConfig.scenes.firstIndex(where: { $0.id == scene.id }) {
            appConfig.scenes[idx] = scene
            appConfig.save()
        }
    }

    func toggleScene(_ id: UUID, enabled: Bool) {
        if let idx = appConfig.scenes.firstIndex(where: { $0.id == id }) {
            appConfig.scenes[idx].enabled = enabled
            appConfig.save()
        }
    }

    func removeScene(_ id: UUID) {
        appConfig.scenes.removeAll { $0.id == id }
        appConfig.save()
    }

    // MARK: - Routing Rules Management

    func addRule(_ rule: RoutingRule) {
        appConfig.routingRules.append(rule)
        appConfig.save()
    }

    func removeRule(_ id: UUID) {
        appConfig.routingRules.removeAll { $0.id == id }
        appConfig.save()
    }

    func toggleRule(_ id: UUID, enabled: Bool) {
        if let idx = appConfig.routingRules.firstIndex(where: { $0.id == id }) {
            appConfig.routingRules[idx].enabled = enabled
            appConfig.save()
        }
    }

    func clearRules() {
        appConfig.routingRules.removeAll()
        appConfig.save()
    }

    // MARK: - Subscription Management

    func importSubscription(name: String, url: String, servers: [Server]) {
        if let idx = appConfig.subscriptions.firstIndex(where: { $0.url == url }) {
            let oldIDs = appConfig.subscriptions[idx].serverIDs
            appConfig.servers.removeAll { oldIDs.contains($0.id) }
            var newIDs: [UUID] = []
            for var server in servers {
                server.subscriptionID = appConfig.subscriptions[idx].id
                appConfig.servers.append(server)
                newIDs.append(server.id)
            }
            appConfig.subscriptions[idx].serverIDs = newIDs
            appConfig.subscriptions[idx].lastUpdated = Date()
        } else {
            let subID = UUID()
            var sub = Subscription(id: subID, name: name, url: url)
            sub.lastUpdated = Date()
            var newIDs: [UUID] = []
            for var server in servers {
                server.subscriptionID = subID
                appConfig.servers.append(server)
                newIDs.append(server.id)
            }
            sub.serverIDs = newIDs
            appConfig.subscriptions.append(sub)
        }
        if appConfig.activeServerID == nil, let first = appConfig.servers.first {
            appConfig.activeServerID = first.id
        }
        appConfig.save()
    }

    func refreshSubscription(_ sub: Subscription) {
        guard let url = URL(string: sub.url) else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let text = String(data: data, encoding: .utf8) else { return }
                let rawLines = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                let lines: [String]
                if rawLines.count == 1, let d = Data(base64Encoded: rawLines[0]),
                   let s = String(data: d, encoding: .utf8) {
                    lines = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                } else {
                    lines = rawLines
                }
                var servers: [Server] = []
                for line in lines {
                    if let server = parseServerURI(line) { servers.append(server) }
                }
                await MainActor.run {
                    self.importSubscription(name: sub.name, url: sub.url, servers: servers)
                }
            } catch {
                print("[VPNManager] Subscription refresh failed: \(error)")
            }
        }
    }

    func refreshAllSubscriptions() {
        for sub in appConfig.subscriptions where sub.autoUpdate {
            refreshSubscription(sub)
        }
    }

    func removeSubscription(_ id: UUID) {
        if let idx = appConfig.subscriptions.firstIndex(where: { $0.id == id }) {
            let serverIDs = appConfig.subscriptions[idx].serverIDs
            appConfig.servers.removeAll { serverIDs.contains($0.id) }
            appConfig.subscriptions.remove(at: idx)
            appConfig.save()
        }
    }

    // MARK: - Network Stats Polling

    private var zeroTrafficSeconds = 0

    private func startStatsPolling() {
        lastStats = NetworkStats.getVPNStats()
        totalBytesIn = 0
        totalBytesOut = 0
        zeroTrafficSeconds = 0
        uploadSpeed = "0 B/s"
        downloadSpeed = "0 B/s"

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.state == .connected else { return }
                let current = NetworkStats.getVPNStats()
                let deltaIn = current.bytesIn >= self.lastStats.bytesIn ? current.bytesIn - self.lastStats.bytesIn : 0
                let deltaOut = current.bytesOut >= self.lastStats.bytesOut ? current.bytesOut - self.lastStats.bytesOut : 0
                self.totalBytesIn += deltaIn
                self.totalBytesOut += deltaOut
                self.downloadSpeed = NetworkStats.formatSpeed(deltaIn)
                self.uploadSpeed = NetworkStats.formatSpeed(deltaOut)
                self.lastStats = current

                // Health check: if zero traffic for 60 seconds on WG/AWG, reconnect
                // Don't health-check non-WG protocols (sing-box handles its own keepalive)
                let isWGProto = self.appConfig.activeServer?.proto == .wireguard || self.appConfig.activeServer?.proto == .amneziawg
                if deltaIn == 0 && deltaOut == 0 && isWGProto {
                    self.zeroTrafficSeconds += 1
                    if self.zeroTrafficSeconds >= 60 {
                        print("[VPNManager] Health check: zero traffic for 60s, reconnecting")
                        self.zeroTrafficSeconds = 0
                        self.disconnect()
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self.userInitiatedDisconnect = false
                        self.wasConnected = true
                        self.connect()
                    }
                } else {
                    self.zeroTrafficSeconds = 0
                }
            }
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    // MARK: - TURN Credentials Cache

    struct CachedTURNCreds {
        let turnUser: String
        let turnPass: String
        let turnAddr: String
        let turnIPs: [String]
        let cachedAt: Date
    }

    private func loadCachedTURNCreds() -> CachedTURNCreds? {
        let defaults = UserDefaults(suiteName: "group.com.swinter.vpn")
        guard let user = defaults?.string(forKey: "turn_cached_user"), !user.isEmpty,
              let pass = defaults?.string(forKey: "turn_cached_pass"), !pass.isEmpty,
              let addr = defaults?.string(forKey: "turn_cached_addr"), !addr.isEmpty,
              let time = defaults?.object(forKey: "turn_cached_time") as? Date else {
            return nil
        }
        // Safety TTL: 24 hours
        if Date().timeIntervalSince(time) > 86400 {
            print("[VPNManager] Cached TURN creds expired (>24h)")
            return nil
        }
        let ips = defaults?.stringArray(forKey: "turn_cached_ips") ?? []
        return CachedTURNCreds(turnUser: user, turnPass: pass, turnAddr: addr, turnIPs: ips, cachedAt: time)
    }

    private func saveCachedTURNCreds(turnUser: String, turnPass: String, turnAddr: String, turnIPs: [String]) {
        let defaults = UserDefaults(suiteName: "group.com.swinter.vpn")
        defaults?.set(turnUser, forKey: "turn_cached_user")
        defaults?.set(turnPass, forKey: "turn_cached_pass")
        defaults?.set(turnAddr, forKey: "turn_cached_addr")
        defaults?.set(turnIPs, forKey: "turn_cached_ips")
        defaults?.set(Date(), forKey: "turn_cached_time")
        print("[VPNManager] TURN creds cached")
    }

    func clearCachedTURNCreds() {
        let defaults = UserDefaults(suiteName: "group.com.swinter.vpn")
        defaults?.removeObject(forKey: "turn_cached_user")
        defaults?.removeObject(forKey: "turn_cached_pass")
        defaults?.removeObject(forKey: "turn_cached_addr")
        defaults?.removeObject(forKey: "turn_cached_ips")
        defaults?.removeObject(forKey: "turn_cached_time")
    }

    // MARK: - Config Import (Shadowrocket/Swinter .conf)

    func importConfig(from urlString: String) {
        Task {
            guard let parsed = await ConfigParser.parseFromURL(urlString) else {
                await MainActor.run { self.lastError = "Не удалось загрузить конфиг" }
                return
            }
            await MainActor.run {
                self.applyParsedConfig(parsed, sourceURL: urlString)
            }
        }
    }

    func importConfig(content: String, sourceURL: String = "") {
        var parsed = ConfigParser.parse(content)
        // Resolve RULE-SETs async
        Task {
            parsed.rules = await ConfigParser.resolveRuleSets(parsed.rules)
            await MainActor.run {
                self.applyParsedConfig(parsed, sourceURL: sourceURL)
            }
        }
    }

    private func applyParsedConfig(_ parsed: ParsedConfig, sourceURL: String) {
        // Apply DNS
        if !parsed.dns.servers.isEmpty || !parsed.dns.dohURL.isEmpty {
            appConfig.dns = parsed.dns
        }

        // Apply rules (replace existing)
        if !parsed.rules.isEmpty {
            appConfig.routingRules = parsed.rules
        }

        // Apply groups
        if !parsed.groups.isEmpty {
            appConfig.groups = parsed.groups
        }

        // Apply TURN overlay to active server
        if let turn = parsed.turnOverlay, let idx = appConfig.servers.firstIndex(where: { $0.id == appConfig.activeServerID }) {
            appConfig.servers[idx].turnOverlay = turn
        }

        // Save config URL for auto-update
        if !sourceURL.isEmpty || !parsed.updateURL.isEmpty {
            appConfig.settings.configURL = parsed.updateURL.isEmpty ? sourceURL : parsed.updateURL
        }

        appConfig.save()
        print("[VPNManager] Config imported: \(parsed.rules.count) rules, \(parsed.groups.count) groups")
    }

    func refreshConfig() {
        let url = appConfig.settings.configURL
        guard !url.isEmpty else { return }
        importConfig(from: url)
    }

    // MARK: - On-Demand Rules

    /// Apply on-demand rules based on AppConfig settings.
    /// This makes iOS automatically reconnect VPN after network loss, reboot, etc.
    private func applyOnDemandRules(to manager: NETunnelProviderManager) {
        let settings = appConfig.settings

        guard settings.alwaysOn || settings.onDemandEnabled else {
            manager.isOnDemandEnabled = false
            return
        }

        var rules: [NEOnDemandRule] = []

        // SSID exceptions — disconnect on these WiFi networks
        if !settings.ssidExceptions.isEmpty {
            let disconnectRule = NEOnDemandRuleDisconnect()
            disconnectRule.ssidMatch = settings.ssidExceptions
            disconnectRule.interfaceTypeMatch = .wiFi
            rules.append(disconnectRule)
        }

        // Disconnect on sleep (saves battery)
        if settings.disconnectOnSleep {
            // iOS doesn't have a direct "sleep" rule, but we can use
            // NEOnDemandRuleIgnore for WiFi when sleeping is simulated
            // The real implementation uses the NE's sleep/wake callbacks
        }

        // Default: always connect
        let connectRule = NEOnDemandRuleConnect()
        connectRule.interfaceTypeMatch = .any
        rules.append(connectRule)

        manager.onDemandRules = rules
        manager.isOnDemandEnabled = true
        print("[VPNManager] On-Demand enabled: \(rules.count) rules, SSID exceptions: \(settings.ssidExceptions)")
    }

    /// Update on-demand settings and re-apply to the active VPN manager.
    func updateOnDemandSettings(alwaysOn: Bool? = nil, ssidExceptions: [String]? = nil) {
        if let alwaysOn = alwaysOn {
            appConfig.settings.alwaysOn = alwaysOn
            appConfig.settings.onDemandEnabled = alwaysOn
        }
        if let ssids = ssidExceptions {
            appConfig.settings.ssidExceptions = ssids
        }
        appConfig.save()

        // Re-apply to active manager if exists
        if let manager = vpnManager {
            applyOnDemandRules(to: manager)
            Task {
                try? await manager.saveToPreferences()
            }
        }
    }

    // MARK: - Save config

    func saveConfig() {
        config.save()
    }

    // MARK: - Status observation

    private func observeStatus() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: vpnManager?.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateState()
            }
        }
    }

    private func updateState() {
        guard let status = vpnManager?.connection.status else {
            state = .disconnected
            return
        }

        print("[VPNManager] Status: \(status.rawValue)")

        switch status {
        case .invalid, .disconnected:
            let previouslyConnected = wasConnected
            state = .disconnected
            Self.saveStateToAppGroup(false)
            // Read NE logs via App Group (don't auto-clear — user reads manually)
            if let defaults = UserDefaults(suiteName: "group.com.swinter.vpn"),
               let tunnelLog = defaults.string(forKey: "tunnel_log"), !tunnelLog.isEmpty {
                print("[NE LOG]\n\(tunnelLog)")
                lastError = tunnelLog.components(separatedBy: "\n").filter { $0.contains("ERROR") || $0.contains("FATAL") }.joined(separator: "\n")
            }
            wasConnected = false
            stopStatsPolling()

            // Auto-reconnect if disconnect was not user-initiated
            if previouslyConnected && !userInitiatedDisconnect {
                print("[VPNManager] ⚠️ Unexpected disconnect (not user-initiated), clearing TURN cache, scheduling reconnect")
                clearCachedTURNCreds() // force fresh creds on reconnect
                scheduleReconnect()
            }
        case .connecting, .reasserting:
            state = .connecting
            // Read MAX Call status from App Group
            if let defaults = UserDefaults(suiteName: "group.com.swinter.vpn"),
               let status = defaults.string(forKey: "maxcall_status"), !status.isEmpty {
                connectingStatus = status
            }
        case .connected:
            // For MAX Call: check if VPN is actually active (not just NE "connected")
            if config.turnSource == .maxCall {
                if let defaults = UserDefaults(suiteName: "group.com.swinter.vpn"),
                   let mcStatus = defaults.string(forKey: "maxcall_status") {
                    if mcStatus.contains("активен") || mcStatus.contains("active") {
                        state = .connected
                        lastError = ""
                        connectingStatus = ""
                        wasConnected = true
                        cancelReconnect()
                        startStatsPolling()
                        Self.saveStateToAppGroup(true)
                    } else {
                        state = .connecting
                        connectingStatus = mcStatus
                    }
                } else {
                    state = .connecting
                    connectingStatus = "MAX Call: запуск..."
                }
            } else {
                state = .connected
                lastError = ""
                connectingStatus = ""
                wasConnected = true
                cancelReconnect()
                startStatsPolling()
                Self.saveStateToAppGroup(true)
            }
        case .disconnecting:
            state = .disconnecting
        @unknown default:
            state = .disconnected
        }
    }

    // MARK: - App Group state (for widget)

    static let appGroupID = "group.com.swinter.vpn"

    static func saveStateToAppGroup(_ connected: Bool) {
        UserDefaults(suiteName: appGroupID)?.set(connected, forKey: "vpn_connected")
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func isConnectedFromAppGroup() -> Bool {
        UserDefaults(suiteName: appGroupID)?.bool(forKey: "vpn_connected") ?? false
    }

    // MARK: - Toggle (for URL scheme)

    func toggle() {
        if state == .connected || state == .connecting {
            disconnect()
        } else if state == .disconnected {
            connect()
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pathMonitor?.cancel()
        reconnectTask?.cancel()
    }
}
