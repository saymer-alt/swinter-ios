# Swinter (iOS) — VPN over MAX Messenger TURN relays

**A VPN that hides inside MAX Messenger voice calls.** Your WireGuard/AmneziaWG traffic is wrapped in DTLS and relayed through MAX's own TURN servers — the same infrastructure MAX uses for audio calls. Russian ISPs can't block these relays without breaking the messenger itself, so the VPN keeps working when direct WG, Outline, and Shadowsocks all go dark.

> **License:** [The Unlicense](LICENSE) — public domain. Do whatever you want. No attribution, no warranty, no lawyers.

---

## Why MAX-TURN?

Modern RKN-era DPI blocks VPN protocols on signature, blocks datacenter IP ranges wholesale, and blocks anything that looks like a "foreign" endpoint. What it **can't** block is MAX Messenger — that's government-pushed infrastructure with hard whitelisting baked into carrier networks. MAX-TURN exploits exactly that: we log into MAX as a normal user, allocate TURN credentials the same way a MAX voice call does, and then pipe our VPN traffic through those relays.

```
 iPhone                MAX relay (whitelisted)         Your VPS
   │                           │                          │
   │── DTLS/TURN ──────────────▶                          │
   │   (looks like a MAX call) │── TURN-relayed UDP ─────▶│
   │                           │                          │──▶ Internet
```

From the ISP's perspective the phone is making a MAX voice call. From the VPS's perspective a WireGuard peer is connecting from a MAX IP. Neither side sees anything unusual.

### How we get TURN credentials

Two mechanisms, fall back from one to the other:

1. **MAX binary TCP auth** — `MaxAuthService.swift` speaks MAX's native protocol (10-byte header + MessagePack frames over TLS to `api.oneme.ru:443`, `deviceType=ANDROID` — `WEB` blocks SMS). After SMS + optional 2FA you get a persistent auth token. `max_creds.go` then uses that token to initiate a call (opcode 78), catch the TURN credentials out of the response, and hang up. Brief phantom ring on the target user, nothing more.
2. **MAX Call WebRTC** — `MaxCallService.swift` wires up WebRTC signaling + a DataChannel through MAX's call pipeline and extracts the ICE/TURN credentials from the SDP.

Credentials are short-lived, so `vpnlib` re-auths on demand. `turn.go` wraps everything in DTLS (via `pion/dtls` + `pion/turn`) and exposes a local `net.Conn` that WireGuard-go treats as its UDP transport.

---

## TURN credential sources

| Source | What it is | Status |
|---|---|---|
| **MAX** | MAX Messenger SMS + 2FA auth, then binary TCP call allocation. **Primary.** | Production |
| **MAX Call** | DataChannel-based TURN via MAX WebRTC signaling. | Production |
| VK | Legacy: TURN credentials scraped from a VK call link. Kept around as a fallback. | Working, deprecated |

---

## Bonus: also a full multi-protocol VPN client

Because the TUN side is protocol-agnostic, Swinter is also a complete VPN app on its own:

- **WireGuard** — standard WG, direct or over MAX-TURN
- **AmneziaWG** — obfuscated WG with DPI bypass
- **VLESS** — TCP + TLS/Reality, Vision flow
- **VMess, Trojan, Shadowsocks** — via the Swinger engine (tun2socks over gvisor netstack)
- **Hysteria2** — planned (quic-go)

Use it as a drop-in replacement for Outline / v2rayNG / Amnezia and ignore MAX-TURN entirely if you want.

---

## Building

### Prerequisites
- Xcode 15+
- Go 1.23+ with `gomobile` (`go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`)
- iOS 15+ target

### Build the Go framework
```bash
cd golib/
gomobile bind -target=ios -o Swinterlib.xcframework ./vpnlib
```

### Build the iOS app
Open `ios/VKTurnVPN.xcodeproj` in Xcode and build. The Network Extension target runs the packet tunnel.

---

## Architecture

```
ios/VKTurnVPN/
├── App/
│   ├── Views/
│   │   ├── MainView.swift           # Home — connect/disconnect
│   │   ├── SettingsView.swift       # Settings
│   │   ├── MaxLoginView.swift       # MAX SMS + 2FA login
│   │   └── ServerListView.swift     # Server management
│   └── VPNManager.swift             # VPN lifecycle
├── Shared/
│   ├── MaxAuthService.swift         # ★ MAX binary TCP auth (SMS + 2FA)
│   └── MaxCallService.swift         # ★ MAX WebRTC call for TURN creds
└── Tunnel/
    └── PacketTunnelProvider.swift   # Network Extension

golib/vpnlib/
├── vpnlib.go                        # StartVPN, ResolveConfig, TURN proxy entry
├── max_creds.go                     # ★ MAX TURN credential extraction
├── turn.go                          # ★ DTLS + TURN relay wrapper
├── config.go                        # ServerConfig (multi-protocol)
├── tun2socks.go                     # gvisor netstack
├── proxy_vless.go / vmess / trojan / ss
├── transport_ws.go                  # WebSocket transport
├── dns_proxy.go                     # DNS proxy for tun2socks
└── tunwrap_ios.go                   # iOS TUN wrapper (4-byte AF header)
```

★ = MAX-TURN core

---

## Features

- **MAX-TURN overlay** — WG/AWG inside MAX voice-call relays
- **MAX SMS + 2FA authentication** with persistent token storage (keychain)
- **MAX Call WebRTC** signaling for dynamic TURN credential refresh
- Network Extension packet tunnel (system-wide VPN)
- AmneziaWG obfuscation
- Multi-protocol Swinger engine (VLESS/VMess/Trojan/SS) for when you don't need MAX-TURN
- Server management with favorites, import/export, subscription URLs

---

## Related

- Android version: [`somewhat-industries/swinter-android`](https://github.com/somewhat-industries/swinter-android)
- MAX binary TCP protocol reverse-engineering credit: `api.oneme.ru:443`, standard TLS, `deviceType=ANDROID` for SMS auth
- DTLS/TURN stack: [`pion/dtls`](https://github.com/pion/dtls), [`pion/turn`](https://github.com/pion/turn)

No warranty. No support. Use at your own risk. If you get your MAX account rate-limited for making too many phantom calls, that's on you.
