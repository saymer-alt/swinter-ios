import NetworkExtension
import os.log
import Vpnlib

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "com.vkturn.vpn.tunnel", category: "tunnel")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("=== START TUNNEL ===", log: log, type: .info)

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration,
              let configJSON = providerConfig["config"] as? String else {
            os_log("ERROR: No config", log: log, type: .error)
            completionHandler(makeError("No configuration"))
            return
        }

        guard let configData = configJSON.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            os_log("ERROR: Bad JSON", log: log, type: .error)
            completionHandler(makeError("Invalid JSON"))
            return
        }

        let wgAddress = config["wgAddress"] as? String ?? "10.7.0.2/32"
        let wgDNS = config["wgDNS"] as? String ?? "1.1.1.1"
        let mtu = config["mtu"] as? Int ?? 1280
        let clientIP = wgAddress.components(separatedBy: "/").first ?? "10.7.0.2"
        let peerAddr = config["peerAddr"] as? String ?? ""
        let vpsIP = peerAddr.components(separatedBy: ":").first ?? ""

        // TURN IPs from main app
        let turnIPsStr = providerConfig["turnIPs"] as? String ?? ""
        let apiIPsStr = providerConfig["apiIPs"] as? String ?? ""
        let turnIPs = turnIPsStr.isEmpty ? [] : turnIPsStr.components(separatedBy: ",")
        let apiIPs = apiIPsStr.isEmpty ? [] : apiIPsStr.components(separatedBy: ",")

        writeLog("Config: clientIP=\(clientIP) vps=\(vpsIP) turnIPs=\(turnIPs)")

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

        // Exclude VPS IP (TURN relay needs to reach it via TURN, not direct)
        // Actually don't exclude VPS — traffic goes through TURN, not directly

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

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("=== STOP TUNNEL reason=%d ===", log: log, type: .info, reason.rawValue)
        VpnlibStopVPN()
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

    // Write logs to App Group so main app can read them
    private func writeLog(_ msg: String) {
        os_log("%{public}@", log: log, type: .info, msg)
        let defaults = UserDefaults(suiteName: "group.com.vkturn.vpn")
        let existing = defaults?.string(forKey: "tunnel_log") ?? ""
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        defaults?.set(existing + "[\(ts)] \(msg)\n", forKey: "tunnel_log")
    }

    private func makeError(_ message: String) -> NSError {
        writeLog("FATAL: \(message)")
        return NSError(domain: "com.vkturn.vpn.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
