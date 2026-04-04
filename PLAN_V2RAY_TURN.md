# Plan: VK TURN via v2ray/xray (iOS + Android)

## Context

Currently the app tunnels WireGuard traffic through VK TURN servers. The idea is to add an alternative: tunnel v2ray/xray traffic through VK TURN instead of WireGuard. This gives access to the full xray protocol suite (VLESS, VMess, Trojan, etc.) over TURN relay.

## Why

- WireGuard is fingerprint-able, v2ray/xray protocols are harder to detect
- xray supports more transport options (WebSocket, gRPC, REALITY)
- Users who already have xray servers don't need a separate WireGuard setup
- Can reuse existing 3x-ui panel configs directly

## Architecture

```
iPhone/Android → DTLS → VK TURN → VPS:56000 → vk-turn-proxy → xray-core (local)
                                                                    ↓
                                                               internet
```

Instead of forwarding TURN traffic to WireGuard (port 51820), forward it to a local xray instance that handles the actual proxying.

## Implementation Plan

### Phase 1: Go Library Changes

**New config mode: `"protocol": "xray"`**

Add to `vpnlib/vpnlib.go`:
- New `StartVPNXray(tunFd int32, configJSON string) error`
- Or: extend `StartVPN` to check a `protocol` field in config JSON
- Config adds: `xrayConfig` field (full xray client JSON or simplified fields)

**Option A — Embed xray-core in Go lib:**
- Add `github.com/xtls/xray-core` as dependency
- Start xray as SOCKS5/HTTP proxy on localhost
- Use tun2socks to route TUN traffic through the local proxy
- Dependencies: `xray-core` (~30MB), `tun2socks`

**Option B — Ship xray binary separately:**
- Bundle `xray` binary in app assets
- Go lib starts TURN proxy → forwards to local port
- Separate process runs xray with the forwarded port as inbound
- Simpler but harder on iOS (no subprocess support in NE)

**Recommendation: Option A for iOS (must be in-process), Option B acceptable for Android.**

### Phase 2: Server Side

On VPS, vk-turn-proxy server forwards to xray instead of WireGuard:

```bash
# Current
vk-turn-server -listen 0.0.0.0:56000 -connect 127.0.0.1:51820

# New: forward to xray inbound (e.g., VLESS on port 443)
vk-turn-server -listen 0.0.0.0:56000 -connect 127.0.0.1:443
```

Or: keep WireGuard AND add a second vk-turn-proxy instance on a different port for xray.

### Phase 3: iOS App Changes

1. Add "v2ray" option to TurnSource enum (under Test Features toggle)
2. Settings UI: xray config fields (address, port, protocol, UUID, etc.)
   - Or: paste full xray client JSON
   - Or: import from 3x-ui subscription link
3. PacketTunnelProvider: when mode is xray, start tun2socks instead of WireGuard
4. Go lib: integrate xray-core + tun2socks

### Phase 4: Android App Changes

Same as iOS but:
- Can optionally use a bundled xray binary (easier)
- Or embed xray-core in the Go AAR (consistent with iOS)
- VpnService creates TUN, routes through tun2socks → xray SOCKS5

### Key Dependencies to Investigate

- `github.com/xtls/xray-core` — can it be compiled with gomobile?
  - It's a large dependency, may increase AAR/xcframework size significantly
  - May have CGO dependencies that break gomobile
- `github.com/xjasonlyu/tun2socks` — Go tun2socks implementation
  - Already used by many VPN apps
  - Works with gomobile
- Alternative: `github.com/nicennnnnnnlee/freedomGo` — lightweight v2ray+tun2socks combo

### Risks

- **Binary size**: xray-core adds ~30-50MB to the Go library
- **gomobile compatibility**: xray-core may use packages that don't compile for mobile
- **Complexity**: tun2socks + xray + TURN proxy is 3 layers vs current 2 (WireGuard + TURN)
- **Performance**: additional proxy hop may reduce throughput

### Recommended Approach

1. Start with a proof-of-concept on Android (easier to debug)
2. Use tun2socks + embedded xray-core in Go lib
3. Test with a simple VLESS config
4. If xray-core is too heavy for gomobile, try sing-box (lighter alternative)
5. Port to iOS once Android PoC works

### Timeline Estimate

This is a significant feature — the Go library changes alone are non-trivial. Suggest implementing as a separate branch and merging once stable.
