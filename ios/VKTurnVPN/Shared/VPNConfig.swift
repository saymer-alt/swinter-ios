import Foundation

// MARK: - VPN State

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

// MARK: - VPN Config

struct VPNConfig: Codable, Equatable {
    var vkLink: String = ""
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
