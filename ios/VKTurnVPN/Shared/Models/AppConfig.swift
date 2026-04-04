import Foundation

// MARK: - Proxy Group

enum GroupType: String, Codable {
    case urlTest     // auto-select lowest latency
    case fallback    // use first available
    case select      // manual selection
}

struct ProxyGroup: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var type: GroupType = .select
    var serverIDs: [UUID] = []
    var testURL: String = "https://www.gstatic.com/generate_204"
    var testInterval: Int = 300     // seconds
    var tolerance: Int = 50         // ms — switch only if faster by this much
}

// MARK: - Scene

enum SceneConditionType: String, Codable {
    case ssid
    case networkType    // wifi / cellular
    case timeRange
}

struct SceneCondition: Codable, Equatable {
    var type: SceneConditionType = .ssid
    var value: String = ""      // SSID name, "wifi"/"cellular", "09:00-18:00"
}

enum SceneActionType: String, Codable {
    case connect
    case disconnect
    case switchServer
    case switchGroup
}

struct SceneAction: Codable, Equatable {
    var type: SceneActionType = .connect
    var targetID: UUID? = nil   // server or group ID
}

struct VPNScene: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var conditions: [SceneCondition] = []
    var action: SceneAction = SceneAction()
    var enabled: Bool = true
}

// MARK: - Routing

enum RuleType: String, Codable, CaseIterable {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCidr = "IP-CIDR"
    case geoip = "GEOIP"
    case final = "FINAL"
}

enum RuleAction: String, Codable, CaseIterable {
    case proxy = "PROXY"
    case direct = "DIRECT"
    case reject = "REJECT"
}

struct RoutingRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: RuleType = .domainSuffix
    var value: String = ""
    var action: RuleAction = .proxy
    var enabled: Bool = true
}

// MARK: - DNS

struct DNSConfig: Codable, Equatable {
    var servers: [String] = ["1.1.1.1", "8.8.8.8"]
    var dohURL: String = ""
    var fallbackServers: [String] = []
}

// MARK: - Subscription

struct Subscription: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var url: String = ""
    var serverIDs: [UUID] = []
    var lastUpdated: Date? = nil
    var autoUpdate: Bool = true
    var updateIntervalHours: Int = 24
}

// MARK: - Global Settings

struct GlobalSettings: Codable, Equatable {
    var onDemandEnabled: Bool = false
    var disconnectOnSleep: Bool = false
    var alwaysOn: Bool = false
    var ssidExceptions: [String] = []
    var iCloudSyncEnabled: Bool = false
    var defaultTurnTargetUserID: String = ""
    var configURL: String = "" // Shadowrocket/Swinter .conf URL for auto-update
}

// MARK: - App Config (root)

struct AppConfig: Codable, Equatable {
    var servers: [Server] = []
    var activeServerID: UUID? = nil
    var groups: [ProxyGroup] = []
    var scenes: [VPNScene] = []
    var routingRules: [RoutingRule] = []
    var dns: DNSConfig = DNSConfig()
    var subscriptions: [Subscription] = []
    var settings: GlobalSettings = GlobalSettings()

    // MARK: - Helpers

    var activeServer: Server? {
        guard let id = activeServerID else { return servers.first }
        return servers.first { $0.id == id }
    }

    mutating func addServer(_ server: Server) {
        servers.append(server)
        if activeServerID == nil {
            activeServerID = server.id
        }
    }

    mutating func removeServer(id: UUID) {
        servers.removeAll { $0.id == id }
        if activeServerID == id {
            activeServerID = servers.first?.id
        }
        // Remove from groups too
        for i in groups.indices {
            groups[i].serverIDs.removeAll { $0 == id }
        }
    }

    // MARK: - Persistence

    private static let configFileName = "swinter_config.json"

    static func load() -> AppConfig {
        guard let url = containerURL(),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            // Try migrating from old VPNConfig
            return migrateFromLegacy()
        }
        return config
    }

    func save() {
        guard let url = Self.containerURL(),
              let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func containerURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.swinter.vpn")?
            .appendingPathComponent(configFileName)
    }

    // MARK: - Migration from legacy VPNConfig

    private static func migrateFromLegacy() -> AppConfig {
        // Try loading old VPNConfig from UserDefaults
        guard let data = UserDefaults.standard.data(forKey: "vpn_config"),
              let old = try? JSONDecoder().decode(LegacyVPNConfig.self, from: data) else {
            return AppConfig()
        }

        var config = AppConfig()
        var server = Server(name: "Legacy Server", address: old.peerAddr, proto: .wireguard)
        server.protocolConfig = .wireguard(WireGuardConfig(
            privateKey: old.wgPrivateKey,
            publicKey: old.wgPublicKey,
            peerAddress: old.peerAddr,
            wgAddress: old.wgAddress,
            dns: old.wgDNS,
            mtu: old.mtu
        ))

        // Migrate TURN overlay
        if !old.maxToken.isEmpty || !old.vkLink.isEmpty {
            let source: TurnOverlaySource = old.maxToken.isEmpty ? .vk : .max
            server.turnOverlay = TurnOverlayConfig(
                source: source,
                vkLink: old.vkLink,
                maxToken: old.maxToken,
                maxTargetUserID: old.maxTargetUserID,
                useUDP: old.useUDP,
                numConns: old.numConns
            )
        }

        config.addServer(server)
        return config
    }
}

// MARK: - Legacy config for migration

private struct LegacyVPNConfig: Codable {
    var vkLink: String = ""
    var maxToken: String = ""
    var maxTargetUserID: String = ""
    var peerAddr: String = ""
    var wgPrivateKey: String = ""
    var wgPublicKey: String = ""
    var wgAddress: String = "10.7.0.2/32"
    var wgDNS: String = "1.1.1.1"
    var useUDP: Bool = false
    var numConns: Int = 16
    var mtu: Int = 1280
}
