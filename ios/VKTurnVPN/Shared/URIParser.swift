import Foundation

/// Parse a protocol URI (vless://, ss://, trojan://, vmess://, hy2://) into a Server object.
func parseServerURI(_ uri: String) -> Server? {
    let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed) else { return nil }

    let scheme = url.scheme?.lowercased() ?? ""
    let host = url.host ?? ""
    let port = url.port ?? 443
    let address = "\(host):\(port)"
    let fragment = url.fragment?.removingPercentEncoding ?? ""
    let params = URLComponents(string: trimmed)?.queryItems?.reduce(into: [String: String]()) {
        $0[$1.name] = $1.value
    } ?? [:]

    switch scheme {
    case "vless":
        var uuid = url.user ?? ""
        var actualHost = host
        var actualPort = port

        // Handle 3x-ui format: vless://base64(uuid@host:port)?params
        // Detect: if "user" looks like base64 and host is empty
        if uuid.isEmpty || (host.isEmpty && !uuid.isEmpty) || uuid.count > 40 {
            // Try decoding the path/user as base64
            let encoded = uuid.isEmpty ? (url.host ?? "") : uuid
            if let decoded = Data(base64Encoded: encoded),
               let str = String(data: decoded, encoding: .utf8) {
                // Format: :uuid@host:port or uuid@host:port
                let clean = str.hasPrefix(":") ? String(str.dropFirst()) : str
                if let atIdx = clean.firstIndex(of: "@") {
                    uuid = String(clean[clean.startIndex..<atIdx])
                    let hostPort = String(clean[clean.index(after: atIdx)...])
                    let parts = hostPort.split(separator: ":")
                    if parts.count >= 2 {
                        actualHost = String(parts[0])
                        actualPort = Int(parts[1]) ?? 443
                    } else {
                        actualHost = hostPort
                    }
                }
            }
        }

        let address = "\(actualHost):\(actualPort)"
        var server = Server(name: fragment.isEmpty ? actualHost : fragment, address: address, proto: .vless)
        let transport: ProxyTransport = {
            switch params["type"] ?? "tcp" {
            case "ws": return .ws
            case "grpc": return .grpc
            case "h2": return .h2
            default: return .tcp
            }
        }()
        // Handle 3x-ui name from "remarks" param
        if let remarks = params["remarks"], !remarks.isEmpty, server.name.isEmpty {
            server.name = remarks
        }

        let tlsMode: TLSMode = {
            // Standard: security=tls/reality/none
            // 3x-ui: tls=1
            let sec = params["security"] ?? (params["tls"] == "1" ? "tls" : "none")
            switch sec {
            case "reality": return .reality
            case "none": return .none
            default: return .tls
            }
        }()
        // Handle flow: standard "flow" param or 3x-ui "xtls=2" (Vision)
        let flow: String = params["flow"] ?? (params["xtls"] == "2" ? "xtls-rprx-vision" : "")

        server.protocolConfig = .vless(VLESSConfig(
            uuid: uuid,
            flow: flow,
            transport: transport,
            tls: tlsMode,
            sni: params["sni"] ?? actualHost,
            fingerprint: params["fp"] ?? "chrome",
            realityPublicKey: params["pbk"] ?? "",
            realityShortId: params["sid"] ?? "",
            wsPath: params["path"] ?? ""
        ))
        return server

    case "ss":
        let userInfo = url.user ?? ""
        let method: String
        let password: String
        // Normalize URL-safe base64 (replace - with +, _ with /) and add padding
        let normalizedB64 = { (s: String) -> String in
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return b
        }(userInfo)
        if let decoded = Data(base64Encoded: normalizedB64), let s = String(data: decoded, encoding: .utf8),
           let sep = s.firstIndex(of: ":") {
            method = String(s[s.startIndex..<sep])
            password = String(s[s.index(after: sep)...])
        } else if let sep = userInfo.firstIndex(of: ":") {
            method = String(userInfo[userInfo.startIndex..<sep])
            password = url.password ?? String(userInfo[userInfo.index(after: sep)...])
        } else {
            return nil
        }
        var server = Server(name: fragment, address: address, proto: .shadowsocks)
        server.protocolConfig = .shadowsocks(ShadowsocksConfig(method: method, password: password))
        return server

    case "trojan":
        let password = url.user ?? ""
        var server = Server(name: fragment, address: address, proto: .trojan)
        server.protocolConfig = .trojan(TrojanConfig(password: password, sni: params["sni"] ?? host))
        return server

    case "vmess":
        var remaining = String(trimmed.dropFirst("vmess://".count))
        // Normalize base64 (URL-safe + padding)
        remaining = remaining.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while remaining.count % 4 != 0 { remaining += "=" }
        guard let data = Data(base64Encoded: remaining),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let vmHost = json["add"] as? String ?? ""
        let vmPort = json["port"] as? Int ?? (Int(json["port"] as? String ?? "443") ?? 443)
        var server = Server(name: json["ps"] as? String ?? "", address: "\(vmHost):\(vmPort)", proto: .vmess)
        let net = json["net"] as? String ?? "tcp"
        let transport: ProxyTransport = net == "ws" ? .ws : net == "grpc" ? .grpc : net == "h2" ? .h2 : .tcp
        let tls: TLSMode = (json["tls"] as? String ?? "") == "tls" ? .tls : .none
        server.protocolConfig = .vmess(VMessConfig(
            uuid: json["id"] as? String ?? "",
            alterId: json["aid"] as? Int ?? 0,
            security: json["scy"] as? String ?? "auto",
            transport: transport, tls: tls,
            sni: json["sni"] as? String ?? vmHost,
            wsPath: json["path"] as? String ?? ""
        ))
        return server

    case "hysteria2", "hy2":
        let password = url.user ?? ""
        var server = Server(name: fragment, address: address, proto: .hysteria2)
        server.protocolConfig = .hysteria2(Hysteria2Config(password: password, sni: params["sni"] ?? host))
        return server

    case "awg", "amneziawg":
        // awg://privateKey@host:port?publicKey=...&presharedKey=...&address=10.8.0.2/24&dns=1.1.1.1&Jc=4&Jmin=40&Jmax=70&S1=73&S2=45&H1=12345678&H2=23456789&H3=34567890&H4=45678901#Name
        let privKey = url.user ?? ""
        var server = Server(name: fragment, address: address, proto: .amneziawg)
        server.protocolConfig = .amneziawg(AmneziaWGConfig(
            privateKey: privKey,
            publicKey: params["publicKey"] ?? params["peer"] ?? "",
            presharedKey: params["presharedKey"] ?? params["psk"] ?? "",
            peerAddress: address,
            wgAddress: params["address"] ?? "10.8.0.2/24",
            dns: params["dns"] ?? "1.1.1.1",
            jc: Int(params["Jc"] ?? "4") ?? 4,
            jmin: Int(params["Jmin"] ?? "40") ?? 40,
            jmax: Int(params["Jmax"] ?? "70") ?? 70,
            s1: Int(params["S1"] ?? "0") ?? 0,
            s2: Int(params["S2"] ?? "0") ?? 0,
            h1: Int(params["H1"] ?? "1") ?? 1,
            h2: Int(params["H2"] ?? "2") ?? 2,
            h3: Int(params["H3"] ?? "3") ?? 3,
            h4: Int(params["H4"] ?? "4") ?? 4
        ))
        return server

    case "wg", "wireguard":
        // wg://privateKey@host:port?publicKey=...&address=10.0.0.2/32&dns=1.1.1.1#Name
        let privKey = url.user ?? ""
        var server = Server(name: fragment, address: address, proto: .wireguard)
        server.protocolConfig = .wireguard(WireGuardConfig(
            privateKey: privKey,
            publicKey: params["publicKey"] ?? params["peer"] ?? "",
            peerAddress: address,
            wgAddress: params["address"] ?? "10.7.0.2/32",
            dns: params["dns"] ?? "1.1.1.1",
            mtu: Int(params["mtu"] ?? "1280") ?? 1280
        ))
        return server

    default:
        return nil
    }
}
