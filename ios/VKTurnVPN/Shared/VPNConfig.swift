import Foundation

// MARK: - VPN State

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

// MARK: - VPN Config

enum TurnSource: String, Codable, CaseIterable {
    case vk = "vk"
    case max = "max"
    case maxCall = "maxCall"

    var title: String {
        switch self {
        case .vk: return "VK TURN"
        case .max: return "MAX TURN"
        case .maxCall: return "MAX Call"
        }
    }
}

struct VPNConfig: Codable, Equatable {
    var turnSource: TurnSource = .vk
    var vkLink: String = ""
    var maxToken: String = ""
    var maxTargetUserID: String = ""
    var maxCallServerPubkey: String = ""  // X25519 hex pubkey for MAX Call mode
    var maxPhone: String = ""  // Phone number used for MAX login (display only)
    var peerAddr: String = ""
    var wgPrivateKey: String = ""
    var wgPublicKey: String = ""
    var wgAddress: String = "10.7.0.2/32"
    var wgDNS: String = "1.1.1.1"
    var turnHost: String = ""
    var turnUser: String = ""
    var turnPass: String = ""
    var turnAddr: String = ""
    var useUDP: Bool = false
    var numConns: Int = 16
    var mtu: Int = 1280

    static let configKey = "vpn_config"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }

    static func load() -> VPNConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let config = try? JSONDecoder().decode(VPNConfig.self, from: data) else {
            return VPNConfig()
        }
        return config
    }

    /// Export config as shareable JSON string (for copy/paste)
    func exportJSON() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Import config from JSON string
    static func importJSON(_ json: String) -> VPNConfig? {
        guard let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(VPNConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// JSON string for passing to Go library
    func toJSON() -> String {
        let dict: [String: Any] = [
            "vkLink": vkLink,
            "peerAddr": peerAddr,
            "wgPrivateKey": wgPrivateKey,
            "wgPublicKey": wgPublicKey,
            "wgAddress": wgAddress,
            "wgDNS": wgDNS,
            "turnHost": turnHost,
            "turnUser": turnUser,
            "turnPass": turnPass,
            "turnAddr": turnAddr,
            "useUDP": useUDP,
            "numConns": numConns,
            "mtu": mtu
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
