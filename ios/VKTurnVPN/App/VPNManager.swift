import Foundation
import NetworkExtension
import Combine
import Vpnlib

@MainActor
class VPNManager: ObservableObject {
    @Published var state: VPNState = .disconnected
    @Published var config: VPNConfig = VPNConfig.load()
    @Published var uploadSpeed: String = "0 KB/s"
    @Published var downloadSpeed: String = "0 KB/s"
    @Published var lastError: String = ""
    @Published var connectingStatus: String = ""

    private var vpnManager: NETunnelProviderManager?
    private var statusObserver: Any?

    init() {
        Task {
            await loadManager()
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

    // MARK: - Connect

    func connect() {
        guard state == .disconnected else { return }
        state = .connecting
        lastError = ""
        connectingStatus = "Подготовка..."

        let vkLink = config.vkLink
        let savedConfig = config

        Task {
            do {
                var resolvedTurnIPs: [String] = []
                var resolvedAPIIPs: [String] = []
                var turnUser = ""
                var turnPass = ""
                var turnAddr = ""
                var lastResolveError = ""

                for attempt in 1...5 {
                    await MainActor.run { self.connectingStatus = "Получаем TURN-креды... (\(attempt)/5)" }
                    print("[VPNManager] Resolve attempt \(attempt)/5...")

                    // Run Go call off main thread
                    let result: (String, NSError?) = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            var err: NSError?
                            let res = VpnlibResolveConfig(vkLink, &err)
                            cont.resume(returning: (res, err))
                        }
                    }

                    if let err = result.1 {
                        lastResolveError = err.localizedDescription
                        print("[VPNManager] Attempt \(attempt) failed: \(lastResolveError)")
                        await MainActor.run { self.connectingStatus = "Попытка \(attempt) не удалась, повтор..." }
                        if attempt < 5 {
                            try await Task.sleep(nanoseconds: 1_500_000_000)
                        }
                        continue
                    }

                    let resolveResult = result.0
                    if !resolveResult.isEmpty,
                       let data = resolveResult.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        resolvedTurnIPs = json["turnIPs"] as? [String] ?? []
                        resolvedAPIIPs = json["apiIPs"] as? [String] ?? []
                        turnUser = json["turnUser"] as? String ?? ""
                        turnPass = json["turnPass"] as? String ?? ""
                        turnAddr = json["turnAddr"] as? String ?? ""
                        print("[VPNManager] OK! TURN: \(turnAddr), IPs: \(resolvedTurnIPs)")
                        break
                    }
                }

                if turnUser.isEmpty {
                    await MainActor.run {
                        self.lastError = "VK API (5 попыток): \(lastResolveError)"
                        self.connectingStatus = ""
                        self.state = .disconnected
                    }
                    return
                }

                await MainActor.run { self.connectingStatus = "TURN: \(turnAddr) — запускаем туннель..." }

                // Step 2: Build enriched config with TURN creds
                var enrichedConfig = savedConfig
                enrichedConfig.turnUser = turnUser
                enrichedConfig.turnPass = turnPass
                enrichedConfig.turnAddr = turnAddr

                let manager = vpnManager ?? NETunnelProviderManager()

                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = "com.vkturn.vpn.tunnel"
                proto.serverAddress = savedConfig.peerAddr.isEmpty ? "VK TURN" : savedConfig.peerAddr

                // Pass EVERYTHING to the tunnel extension
                proto.providerConfiguration = [
                    "config": enrichedConfig.toJSON(),
                    "turnIPs": resolvedTurnIPs.joined(separator: ","),
                    "apiIPs": resolvedAPIIPs.joined(separator: ",")
                ]

                manager.protocolConfiguration = proto
                manager.localizedDescription = "VK Turn VPN"
                manager.isEnabled = true

                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()

                await MainActor.run {
                    self.vpnManager = manager
                    self.observeStatus()
                }

                let session = manager.connection as! NETunnelProviderSession
                try session.startTunnel(options: nil)

                print("[VPNManager] Tunnel start requested")

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

    // MARK: - Disconnect

    func disconnect() {
        guard state == .connected else { return }
        state = .disconnecting
        vpnManager?.connection.stopVPNTunnel()
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
            state = .disconnected
            // Read NE logs via App Group
            if let defaults = UserDefaults(suiteName: "group.com.vkturn.vpn"),
               let tunnelLog = defaults.string(forKey: "tunnel_log"), !tunnelLog.isEmpty {
                print("[NE LOG]\n\(tunnelLog)")
                lastError = tunnelLog.components(separatedBy: "\n").filter { $0.contains("ERROR") || $0.contains("FATAL") }.joined(separator: "\n")
                defaults.removeObject(forKey: "tunnel_log")
            }
        case .connecting, .reasserting:
            state = .connecting
        case .connected:
            state = .connected
            lastError = ""
            connectingStatus = ""
        case .disconnecting:
            state = .disconnecting
        @unknown default:
            state = .disconnected
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
