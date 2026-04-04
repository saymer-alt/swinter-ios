# Swinter VPN (iOS)

Multi-protocol VPN client with MAX/VK TURN overlay for censorship circumvention.

## Supported Protocols

- **WireGuard** — standard WG direct or via TURN
- **AmneziaWG** — obfuscated WG with DPI bypass
- **VLESS** — TCP + TLS/Reality, Vision flow
- **VMess, Trojan, Shadowsocks** — via Swinger engine (tun2socks)
- **Hysteria2** — planned (quic-go)

## TURN Overlay

WireGuard/AmneziaWG traffic routed through VK/MAX TURN servers (whitelisted by ISPs):

```
iPhone → DTLS/TURN → VK/MAX relay (whitelisted) → VPS → Internet
```

TURN sources:
- **VK** — VK call link
- **MAX** — MAX Messenger SMS auth (with 2FA support)
- **MAX Call** — DataChannel-based TURN via WebRTC signaling

## Building

### Prerequisites
- Xcode 15+
- Go 1.23+, gomobile
- iOS 15+ target

### Build Go framework
```bash
cd golib/
gomobile bind -target=ios -o Vpnlib.xcframework ./vpnlib
```

### Build iOS app
Open `ios/VKTurnVPN.xcodeproj` in Xcode and build.

## Architecture

```
ios/VKTurnVPN/
├── App/
│   ├── Views/
│   │   ├── ContentView.swift      # Main UI
│   │   ├── SettingsView.swift     # Settings
│   │   ├── MaxLoginView.swift     # MAX SMS + 2FA login
│   │   └── ServerListView.swift   # Server management
│   └── VPNManager.swift           # VPN lifecycle
├── Shared/
│   ├── MaxAuthService.swift       # MAX binary TCP auth
│   └── MaxCallService.swift       # MAX WebRTC call for TURN
└── Tunnel/
    └── PacketTunnelProvider.swift  # Network Extension

golib/vpnlib/
├── vpnlib.go          # Main: StartVPN, ResolveConfig, TURN proxy
├── config.go          # ServerConfig (multi-protocol)
├── tun2socks.go       # gvisor netstack
├── proxy_vless.go     # VLESS client (TLS + Reality + Vision)
├── proxy_vmess.go     # VMess client
├── proxy_trojan.go    # Trojan client
├── proxy_ss.go        # Shadowsocks AEAD
├── transport_ws.go    # WebSocket transport
├── dns_proxy.go       # DNS proxy for tun2socks
├── tunwrap_ios.go     # iOS TUN wrapper (4-byte AF header)
├── tunwrap_android.go # Android TUN wrapper
└── turn.go            # TURN/DTLS proxy
```

## Features

- Network Extension (packet tunnel) for system-wide VPN
- MAX SMS + 2FA authentication
- VK call link TURN resolution
- MAX Call WebRTC signaling for TURN
- Multi-protocol Swinger engine (VLESS/VMess/Trojan/SS)
- AmneziaWG obfuscation
- Server management with favorites
- Config import/export
- Subscription URL support
