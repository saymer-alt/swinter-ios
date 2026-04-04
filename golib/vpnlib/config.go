package vpnlib

// Config structs for JSON exchange between native apps and Go library.
// These mirror the Swift/Kotlin Server model.

// ServerConfig is the top-level config passed from native to StartVPN.
type ServerConfig struct {
	Protocol string `json:"protocol"` // wireguard, vless, vmess, trojan, shadowsocks, hysteria2, socks5, http
	Address  string `json:"address"`  // host:port

	// Protocol-specific
	WireGuard   *WireGuardConf   `json:"wireguard,omitempty"`
	VLESS       *VLESSConf       `json:"vless,omitempty"`
	VMess       *VMessConf       `json:"vmess,omitempty"`
	Trojan      *TrojanConf      `json:"trojan,omitempty"`
	Shadowsocks *ShadowsocksConf `json:"shadowsocks,omitempty"`
	Hysteria2   *Hysteria2Conf   `json:"hysteria2,omitempty"`
	Socks5      *Socks5Conf      `json:"socks5,omitempty"`
	HTTP        *HTTPConf        `json:"http,omitempty"`

	// TURN overlay (optional, WireGuard only)
	TURN *TURNConf `json:"turn,omitempty"`

	// Routing & DNS
	Rules []RouteRule `json:"rules,omitempty"`
	DNS   *DNSConf    `json:"dns,omitempty"`
}

type WireGuardConf struct {
	PrivateKey   string `json:"privateKey"`
	PublicKey    string `json:"publicKey"`
	PresharedKey string `json:"presharedKey,omitempty"`
	PeerAddress  string `json:"peerAddress"` // endpoint host:port (same as ServerConfig.Address usually)
	WGAddress    string `json:"wgAddress"`   // e.g. 10.7.0.2/32
	DNS          string `json:"dns"`
	MTU          int    `json:"mtu"`
	// AmneziaWG obfuscation parameters
	Jc   int `json:"jc,omitempty"`
	Jmin int `json:"jmin,omitempty"`
	Jmax int `json:"jmax,omitempty"`
	S1   int `json:"s1,omitempty"`
	S2   int `json:"s2,omitempty"`
	H1   int `json:"h1,omitempty"`
	H2   int `json:"h2,omitempty"`
	H3   int `json:"h3,omitempty"`
	H4   int `json:"h4,omitempty"`
}

type VLESSConf struct {
	UUID             string `json:"uuid"`
	Flow             string `json:"flow,omitempty"`             // xtls-rprx-vision
	Transport        string `json:"transport"`                  // tcp, ws, grpc, h2
	TLS              string `json:"tls"`                        // none, tls, reality
	SNI              string `json:"sni,omitempty"`
	Fingerprint      string `json:"fingerprint,omitempty"`      // chrome, firefox, safari, random
	RealityPublicKey string `json:"realityPublicKey,omitempty"`
	RealityShortID   string `json:"realityShortId,omitempty"`
	WSPath           string `json:"wsPath,omitempty"`
	GRPCServiceName  string `json:"grpcServiceName,omitempty"`
}

type VMessConf struct {
	UUID      string `json:"uuid"`
	AlterID   int    `json:"alterId"`
	Security  string `json:"security"`  // auto, aes-128-gcm, chacha20-poly1305
	Transport string `json:"transport"` // tcp, ws, grpc, h2
	TLS       string `json:"tls"`       // none, tls
	SNI       string `json:"sni,omitempty"`
	WSPath    string `json:"wsPath,omitempty"`
}

type TrojanConf struct {
	Password  string `json:"password"`
	Transport string `json:"transport"`
	TLS       string `json:"tls"`
	SNI       string `json:"sni,omitempty"`
	WSPath    string `json:"wsPath,omitempty"`
}

type ShadowsocksConf struct {
	Method   string `json:"method"`   // aes-256-gcm, chacha20-ietf-poly1305, 2022-blake3-aes-256-gcm
	Password string `json:"password"`
}

type Hysteria2Conf struct {
	Password     string `json:"password"`
	Obfs         string `json:"obfs,omitempty"`
	ObfsPassword string `json:"obfsPassword,omitempty"`
	UploadMbps   int    `json:"uploadMbps"`
	DownloadMbps int    `json:"downloadMbps"`
	SNI          string `json:"sni,omitempty"`
}

type Socks5Conf struct {
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
	TLS      bool   `json:"tls"`
}

type HTTPConf struct {
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
	TLS      bool   `json:"tls"`
}

type TURNConf struct {
	Source          string `json:"source"`          // vk, max
	VKLink          string `json:"vkLink,omitempty"`
	MaxToken        string `json:"maxToken,omitempty"`
	MaxTargetUserID int64  `json:"maxTargetUserID,omitempty"`
	UseUDP          bool   `json:"useUDP"`
	NumConns        int    `json:"numConns"`
	// Resolved credentials (filled by Go after resolution)
	TurnUser string `json:"turnUser,omitempty"`
	TurnPass string `json:"turnPass,omitempty"`
	TurnAddr string `json:"turnAddr,omitempty"`
}

type RouteRule struct {
	Type   string `json:"type"`   // DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, IP-CIDR, GEOIP, FINAL
	Value  string `json:"value"`
	Action string `json:"action"` // PROXY, DIRECT, REJECT
}

type DNSConf struct {
	Servers  []string `json:"servers"`
	DoHURL   string   `json:"dohURL,omitempty"`
	Fallback []string `json:"fallback,omitempty"`
}

// LegacyConfig is the old flat config format for backward compatibility.
// Kept for migration and for existing TURN-only connect flows.
type LegacyConfig = config // alias to existing config struct in vpnlib.go
