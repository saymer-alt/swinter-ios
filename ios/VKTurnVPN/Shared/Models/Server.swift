import Foundation

// MARK: - Protocol Type

enum ProxyProtocol: String, Codable, CaseIterable, Identifiable {
    case wireguard
    case amneziawg
    case vless
    case vmess
    case trojan
    case shadowsocks
    case hysteria2
    case socks5
    case http

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wireguard: return "WireGuard"
        case .amneziawg: return "AmneziaWG"
        case .vless: return "VLESS"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .shadowsocks: return "Shadowsocks"
        case .hysteria2: return "Hysteria2"
        case .socks5: return "SOCKS5"
        case .http: return "HTTP"
        }
    }

    var supportsTURN: Bool {
        self == .wireguard || self == .amneziawg
    }
}

// MARK: - Transport

enum ProxyTransport: String, Codable, CaseIterable {
    case tcp
    case ws
    case grpc
    case h2
    case quic

    var displayName: String {
        switch self {
        case .tcp: return "TCP"
        case .ws: return "WebSocket"
        case .grpc: return "gRPC"
        case .h2: return "HTTP/2"
        case .quic: return "QUIC"
        }
    }
}

// MARK: - TLS Mode

enum TLSMode: String, Codable, CaseIterable {
    case none
    case tls
    case reality

    var displayName: String {
        switch self {
        case .none: return "None"
        case .tls: return "TLS"
        case .reality: return "Reality"
        }
    }
}

// MARK: - Protocol Configs

struct WireGuardConfig: Codable, Equatable {
    var privateKey: String = ""
    var publicKey: String = ""
    var presharedKey: String = ""
    var peerAddress: String = ""
    var wgAddress: String = "10.7.0.2/32"
    var dns: String = "1.1.1.1"
    var mtu: Int = 1280
}

struct AmneziaWGConfig: Codable, Equatable {
    var privateKey: String = ""
    var publicKey: String = ""
    var presharedKey: String = ""
    var peerAddress: String = ""
    var wgAddress: String = "10.8.0.2/24"
    var dns: String = "1.1.1.1"
    var mtu: Int = 1280
    // AmneziaWG obfuscation parameters
    var jc: Int = 4          // Junk packet count
    var jmin: Int = 40       // Min junk packet size
    var jmax: Int = 70       // Max junk packet size
    var s1: Int = 0          // Init packet magic header padding
    var s2: Int = 0          // Response packet magic header padding
    var h1: Int = 1          // Init packet header type
    var h2: Int = 2          // Response packet header type
    var h3: Int = 3          // Cookie packet header type
    var h4: Int = 4          // Transport packet header type
}

struct VLESSConfig: Codable, Equatable {
    var uuid: String = ""
    var flow: String = ""               // xtls-rprx-vision
    var transport: ProxyTransport = .tcp
    var tls: TLSMode = .tls
    var sni: String = ""
    var fingerprint: String = "chrome"  // uTLS fingerprint
    var realityPublicKey: String = ""
    var realityShortId: String = ""
    var wsPath: String = ""
    var grpcServiceName: String = ""
}

struct VMessConfig: Codable, Equatable {
    var uuid: String = ""
    var alterId: Int = 0
    var security: String = "auto"       // auto, aes-128-gcm, chacha20-poly1305
    var transport: ProxyTransport = .tcp
    var tls: TLSMode = .none
    var sni: String = ""
    var wsPath: String = ""
}

struct TrojanConfig: Codable, Equatable {
    var password: String = ""
    var transport: ProxyTransport = .tcp
    var tls: TLSMode = .tls
    var sni: String = ""
    var wsPath: String = ""
}

struct ShadowsocksConfig: Codable, Equatable {
    var method: String = "aes-256-gcm"  // aes-256-gcm, chacha20-ietf-poly1305, 2022-blake3-aes-256-gcm
    var password: String = ""
}

struct Hysteria2Config: Codable, Equatable {
    var password: String = ""
    var obfs: String = ""               // salamander
    var obfsPassword: String = ""
    var uploadMbps: Int = 100
    var downloadMbps: Int = 100
    var sni: String = ""
}

struct Socks5Config: Codable, Equatable {
    var username: String = ""
    var password: String = ""
    var tls: Bool = false
}

struct HTTPProxyConfig: Codable, Equatable {
    var username: String = ""
    var password: String = ""
    var tls: Bool = false
}

// MARK: - Protocol Config (polymorphic)

enum ProtocolConfig: Codable, Equatable {
    case wireguard(WireGuardConfig)
    case amneziawg(AmneziaWGConfig)
    case vless(VLESSConfig)
    case vmess(VMessConfig)
    case trojan(TrojanConfig)
    case shadowsocks(ShadowsocksConfig)
    case hysteria2(Hysteria2Config)
    case socks5(Socks5Config)
    case http(HTTPProxyConfig)

    static func defaultConfig(for proto: ProxyProtocol) -> ProtocolConfig {
        switch proto {
        case .wireguard: return .wireguard(WireGuardConfig())
        case .amneziawg: return .amneziawg(AmneziaWGConfig())
        case .vless: return .vless(VLESSConfig())
        case .vmess: return .vmess(VMessConfig())
        case .trojan: return .trojan(TrojanConfig())
        case .shadowsocks: return .shadowsocks(ShadowsocksConfig())
        case .hysteria2: return .hysteria2(Hysteria2Config())
        case .socks5: return .socks5(Socks5Config())
        case .http: return .http(HTTPProxyConfig())
        }
    }
}

// MARK: - TURN Overlay

enum TurnOverlaySource: String, Codable, CaseIterable {
    case vk
    case max

    var displayName: String {
        switch self {
        case .vk: return "VK TURN"
        case .max: return "MAX TURN"
        }
    }
}

struct TurnOverlayConfig: Codable, Equatable {
    var source: TurnOverlaySource = .max
    var vkLink: String = ""
    var maxToken: String = ""
    var maxTargetUserID: String = ""
    var useUDP: Bool = true
    var numConns: Int = 4
}

// MARK: - Server

struct Server: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var address: String = ""            // host:port
    var proto: ProxyProtocol = .wireguard
    var protocolConfig: ProtocolConfig
    var turnOverlay: TurnOverlayConfig? = nil
    var latencyMs: Int? = nil
    var enabled: Bool = true
    var isFavorite: Bool = false
    var subscriptionID: UUID? = nil
    var createdAt: Date = Date()

    init(name: String = "", address: String = "", proto: ProxyProtocol = .wireguard) {
        self.name = name
        self.address = address
        self.proto = proto
        self.protocolConfig = .defaultConfig(for: proto)
    }
}
