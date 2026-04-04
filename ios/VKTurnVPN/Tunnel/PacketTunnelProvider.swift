import NetworkExtension
import os.log
import Swinterlib
#if canImport(WebRTC)
import WebRTC
#endif

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "com.swinter.vpn.tunnel", category: "tunnel")
    #if canImport(WebRTC)
    private var maxCallService: MaxCallService?
    #endif
    private var udpVPNClient: UDPVPNClient?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("=== START TUNNEL ===", log: log, type: .info)
        // Clear old logs on each tunnel start
        UserDefaults(suiteName: "group.com.swinter.vpn")?.removeObject(forKey: "tunnel_log")

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration,
              let configJSON = providerConfig["config"] as? String else {
            os_log("ERROR: No config", log: log, type: .error)
            completionHandler(makeError("No configuration"))
            return
        }

        // Check if this is MAX Call mode
        let mode = providerConfig["mode"] as? String ?? ""
        if mode == "maxCall" {
            startMaxCallTunnel(configJSON: configJSON, completionHandler: completionHandler)
            return
        }

        guard let configData = configJSON.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            os_log("ERROR: Bad JSON", log: log, type: .error)
            completionHandler(makeError("Invalid JSON"))
            return
        }

        // Check if this is a new-style multi-protocol config
        let vpnProtocol = config["protocol"] as? String ?? ""

        // Non-WG protocols: use sing-box
        if !vpnProtocol.isEmpty && vpnProtocol != "wireguard" && vpnProtocol != "amneziawg" {
            writeLog("Protocol: \(vpnProtocol) — starting Swinger")
            writeLog("Config: \(String(configJSON.prefix(500)))")

            let serverHost = (config["address"] as? String ?? "").components(separatedBy: ":").first ?? ""

            // Configure TUN (same approach as WireGuard)
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
            settings.mtu = 1280 as NSNumber

            let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
            ipv4.includedRoutes = [NEIPv4Route.default()]
            if !serverHost.isEmpty {
                ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverHost, subnetMask: "255.255.255.255")]
            }
            settings.ipv4Settings = ipv4
            settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])

            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.writeLog("Settings error: \(error)")
                    completionHandler(error)
                    return
                }
                self.writeLog("Tunnel settings OK")
                completionHandler(nil)

                // Get TUN fd (same as WireGuard path)
                guard let tunFd = self.getTunnelFileDescriptor() else {
                    self.writeLog("ERROR: no TUN fd")
                    self.cancelTunnelWithError(self.makeError("No TUN fd"))
                    return
                }
                self.writeLog("TUN fd=\(tunFd)")

                // Start Swinger with TUN fd — gvisor reads packets, proxies through VLESS
                DispatchQueue.global(qos: .userInitiated).async {
                    var err: NSError?
                    VpnlibStartSingBox(tunFd, configJSON, &err)
                    if let err = err {
                        self.writeLog("Swinger ERROR: \(err.localizedDescription)")
                        self.cancelTunnelWithError(err)
                    } else {
                        self.writeLog("Swinger OK — tun2socks active")
                    }
                }
            }
            return
        }

        let wgAddress = config["wgAddress"] as? String ?? config["wireguard.wgAddress"] as? String ?? "10.7.0.2/32"
        let wgDNS = config["wgDNS"] as? String ?? config["wireguard.dns"] as? String ?? "1.1.1.1"
        let mtu = config["mtu"] as? Int ?? (config["wireguard"] as? [String: Any])?["mtu"] as? Int ?? 1280
        let clientIP = wgAddress.components(separatedBy: "/").first ?? "10.7.0.2"
        let peerAddr = config["peerAddr"] as? String ?? config["address"] as? String ?? ""
        let vpsIP = peerAddr.components(separatedBy: ":").first ?? ""

        // TURN IPs from main app
        let turnIPsStr = providerConfig["turnIPs"] as? String ?? ""
        let apiIPsStr = providerConfig["apiIPs"] as? String ?? ""
        let turnIPs = turnIPsStr.isEmpty ? [] : turnIPsStr.components(separatedBy: ",")
        let apiIPs = apiIPsStr.isEmpty ? [] : apiIPsStr.components(separatedBy: ",")

        // Detailed logging
        let hasTurnUser = (config["turnUser"] as? String ?? "").isEmpty == false
        let hasTurnPass = (config["turnPass"] as? String ?? "").isEmpty == false
        let turnAddr = config["turnAddr"] as? String ?? ""
        let vkLink = config["vkLink"] as? String ?? ""
        let useUDP = config["useUDP"] as? Bool ?? false
        let numConns = config["numConns"] as? Int ?? 16
        let wgPriv = (config["wgPrivateKey"] as? String ?? "").prefix(8)
        let wgPub = (config["wgPublicKey"] as? String ?? "").prefix(8)

        writeLog("Config: clientIP=\(clientIP) vps=\(vpsIP) mtu=\(mtu)")
        writeLog("WG: priv=\(wgPriv)... pub=\(wgPub)...")
        writeLog("TURN: hasCreds=\(hasTurnUser && hasTurnPass) addr=\(turnAddr) vkLink=\(vkLink.prefix(30)) udp=\(useUDP) conns=\(numConns)")
        writeLog("Protocol: \(vpnProtocol.isEmpty ? "wireguard(legacy)" : vpnProtocol)")
        writeLog("TurnIPs: \(turnIPs) ApiIPs: \(apiIPs)")
        writeLog("Full peerAddr: \(peerAddr)")

        // Build excluded routes
        var excluded: [NEIPv4Route] = []

        // Exclude resolved TURN IPs
        for ip in turnIPs + apiIPs {
            let trimmed = ip.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                excluded.append(NEIPv4Route(destinationAddress: trimmed, subnetMask: "255.255.255.255"))
            }
        }

        // Exclude VK subnets (fallback)
        let vkSubnets: [(String, String)] = [
            ("87.240.128.0", "255.255.192.0"),     // VK main
            ("93.186.224.0", "255.255.252.0"),      // VK
            ("95.142.192.0", "255.255.248.0"),      // VK
            ("95.213.0.0", "255.255.192.0"),        // Mail.ru
            ("185.32.185.0", "255.255.255.0"),      // VK Calls
            ("5.255.211.0", "255.255.255.0"),       // Yandex
            ("155.212.0.0", "255.255.0.0"),         // VK TURN (wider range)
        ]
        for (addr, mask) in vkSubnets {
            excluded.append(NEIPv4Route(destinationAddress: addr, subnetMask: mask))
        }

        os_log("Excluded routes: %d", log: log, type: .info, excluded.count)

        // Tunnel settings
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        settings.mtu = NSNumber(value: mtu)

        let ipv4 = NEIPv4Settings(addresses: [clientIP], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = excluded
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: wgDNS.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) })

        // Apply settings and tell iOS we're ready IMMEDIATELY
        // Then start Go VPN in background
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                os_log("Tunnel settings error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }

            self.writeLog("Tunnel settings OK")
            completionHandler(nil)

            guard let tunFd = self.getTunnelFileDescriptor() else {
                self.cancelTunnelWithError(self.makeError("No TUN fd found"))
                return
            }
            self.writeLog("TUN fd=\(tunFd)")

            // Start Go VPN on background thread
            DispatchQueue.global(qos: .userInitiated).async {
                self.writeLog("Starting VpnlibStartVPN with fd=\(tunFd)")
                var vpnErr: NSError?
                VpnlibStartVPN(tunFd, configJSON, &vpnErr)
                if let vpnErr = vpnErr {
                    self.writeLog("ERROR: \(vpnErr.localizedDescription)")
                    self.cancelTunnelWithError(vpnErr)
                } else {
                    self.writeLog("VPN started OK")
                }
            }
        }
    }

    // MARK: - MAX Call Tunnel

    private func startMaxCallTunnel(configJSON: String, completionHandler: @escaping (Error?) -> Void) {
        writeLog("=== MAX CALL MODE ===")

        guard let configData = configJSON.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            completionHandler(makeError("Bad MAX Call config"))
            return
        }

        let maxToken = config["maxToken"] as? String ?? ""
        let serverUserID = Int(config["maxTargetUserID"] as? String ?? "0") ?? 0
        let serverPubkey = config["maxCallServerPubkey"] as? String ?? ""
        let _ = config["deviceId"] as? String ?? UUID().uuidString

        guard !maxToken.isEmpty, serverUserID > 0, !serverPubkey.isEmpty else {
            completionHandler(makeError("Missing MAX Call params"))
            return
        }

        writeLog("Starting UDP VPN to 5.61.39.52:56001...")

        let client = UDPVPNClient(
            serverHost: "5.61.39.52",
            serverPort: 56001,
            serverPubkeyHex: serverPubkey
        )
        self.udpVPNClient = client

        client.onStatus = { [weak self] (text: String) in
            self?.writeLog("Status: \(text)")
            // Also write to maxcall_status so main app can show it
            UserDefaults(suiteName: "group.com.swinter.vpn")?.set(text, forKey: "maxcall_status")
        }

        client.onError = { [weak self] (text: String) in
            self?.writeLog("ERROR: \(text)")
            self?.cancelTunnelWithError(self?.makeError(text) ?? NSError())
        }

        client.onPacket = { [weak self] packet in
            self?.packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
        }

        client.onConnected = { [weak self] in
            guard let self = self else { return }
            self.writeLog("VPN CONNECTED! Key exchange done. Applying routes...")

            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.1")
            settings.mtu = 1200
            let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv4.excludedRoutes = [
                NEIPv4Route(destinationAddress: "5.61.39.52", subnetMask: "255.255.255.255"),
            ]
            settings.ipv4Settings = ipv4
            settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])

            self.setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.writeLog("Routes error: \(error)")
                } else {
                    self.writeLog("Routes applied! VPN FULLY ACTIVE!")
                    UserDefaults(suiteName: "group.com.swinter.vpn")?.set("VPN активен через UDP", forKey: "maxcall_status")
                    self.startUDPTUNReadLoop()
                }
            }
        }

        // Tell iOS we're "up" immediately, then connect
        completionHandler(nil)
        client.start()
    }

    private func startUDPTUNReadLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, let client = self.udpVPNClient else { return }
            for packet in packets {
                client.sendPacket(packet)
            }
            self.startUDPTUNReadLoop()
        }
    }

    #if canImport(WebRTC)
    private func startTUNReadLoop(service: MaxCallService) {
        packetFlow.readPackets { [weak self] packets, protocols in
            for packet in packets {
                service.sendPacket(packet)
            }
            self?.startTUNReadLoop(service: service)
        }
    }
    #endif

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("=== STOP TUNNEL reason=%d ===", log: log, type: .info, reason.rawValue)
        if let client = udpVPNClient {
            client.stop()
            udpVPNClient = nil
        } else {
            // Stop both — one of them will be running
            VpnlibStopVPN()
            VpnlibStopSingBox()
            #if canImport(WebRTC)
            if let service = maxCallService {
                service.stop()
                maxCallService = nil
            }
            #endif
        }
        completionHandler()
    }

    private func getTunnelFileDescriptor() -> Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            if getsockopt(fd, 2, 2, &buf, &len) == 0 {
                let name = String(cString: buf)
                if name.hasPrefix("utun") {
                    return fd
                }
            }
        }
        return self.packetFlow.value(forKey: "socket.fileDescriptor") as? Int32
    }

    // Write logs to App Group so main app can read them (capped at 8KB to avoid NE OOM)
    private func writeLog(_ msg: String) {
        os_log("%{public}@", log: log, type: .info, msg)
        let defaults = UserDefaults(suiteName: "group.com.swinter.vpn")
        var existing = defaults?.string(forKey: "tunnel_log") ?? ""
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        existing += "[\(ts)] \(msg)\n"
        // Keep only last 8KB to prevent unbounded growth in NE memory
        if existing.count > 8192 {
            existing = String(existing.suffix(6144))
        }
        defaults?.set(existing, forKey: "tunnel_log")
    }

    // Keep NE alive by continuously reading TUN packets
    private func startPacketForwarding() {
        packetFlow.readPackets { [weak self] packets, protocols in
            // Packets arrive here from TUN — but NEProxySettings handles routing
            // We just need to keep reading to keep NE alive
            self?.startPacketForwarding()
        }
    }

    private func resolveHost(_ hostname: String) throws -> [String] {
        let cfHost = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
        CFHostStartInfoResolution(cfHost, .addresses, nil)
        var success: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(cfHost, &success)?.takeUnretainedValue() as? [Data] else {
            return [hostname]
        }
        var results: [String] = []
        for addr in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            addr.withUnsafeBytes { ptr in
                let sa = ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                getnameinfo(sa, socklen_t(addr.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            }
            let ip = String(cString: hostname)
            if !ip.isEmpty && !ip.contains(":") { // IPv4 only
                results.append(ip)
            }
        }
        return results
    }

    private func hostToIP(host: String) -> String {
        return host // fallback
    }

    private func makeError(_ message: String) -> NSError {
        writeLog("FATAL: \(message)")
        return NSError(domain: "com.swinter.vpn.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
