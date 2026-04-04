import Foundation
import Network
import os.log

/// Direct UDP VPN client. Connects to VPS, does key exchange + ChaCha20.
/// No WebRTC, no TURN. Uses NWConnection which bypasses NE tunnel.
class UDPVPNClient {
    let serverHost: String
    let serverPort: UInt16
    let serverPubkeyHex: String

    private let log = OSLog(subsystem: "com.swinter.vpn.tunnel", category: "udpvpn")
    private var connection: NWConnection?
    private var clientKeyPair: VPNKeyPair?
    private var sendCipher: VPNCipher?
    private var recvCipher: VPNCipher?

    var onConnected: (() -> Void)?
    var onPacket: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?

    init(serverHost: String, serverPort: UInt16, serverPubkeyHex: String) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.serverPubkeyHex = serverPubkeyHex
    }

    func start() {
        onStatus?("UDP: подключение к \(serverHost):\(serverPort)...")
        os_log("Connecting to %{public}@:%d", log: log, type: .info, serverHost, serverPort)

        let host = NWEndpoint.Host(serverHost)
        let port = NWEndpoint.Port(rawValue: serverPort)!

        // Use parameters that bypass VPN tunnel
        let params = NWParameters.udp
        params.requiredInterfaceType = .wifi  // Prefer WiFi (physical interface)

        connection = NWConnection(host: host, port: port, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                os_log("UDP connection ready", log: self.log, type: .info)
                self.onStatus?("UDP: подключено, обмен ключами...")
                self.doHandshake()
            case .failed(let error):
                os_log("UDP failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.onError?("UDP failed: \(error.localizedDescription)")
            case .waiting(let error):
                os_log("UDP waiting: %{public}@", log: self.log, type: .info, error.localizedDescription)
            default:
                break
            }
        }

        connection?.start(queue: .global(qos: .userInitiated))
        startReceiving()
    }

    private func doHandshake() {
        clientKeyPair = VPNKeyPair()
        let hello = buildHandshakeMsg(publicBytes: clientKeyPair!.publicBytes)
        connection?.send(content: hello, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.onError?("Handshake send error: \(error)")
            } else {
                os_log("Handshake sent", log: self?.log ?? .default, type: .info)
            }
        })
    }

    private func startReceiving() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error {
                os_log("Receive error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                return
            }
            if let data = data, !data.isEmpty {
                self.handleReceived(data)
            }
            // Continue receiving
            self.startReceiving()
        }
    }

    private func handleReceived(_ data: Data) {
        // Handshake response?
        if sendCipher == nil {
            do {
                let serverPub = try parseHandshakeMsg(data)
                let expectedPub = Data(hexString: serverPubkeyHex)

                guard serverPub == expectedPub else {
                    onError?("Server key mismatch!")
                    return
                }

                guard let kp = clientKeyPair else { return }
                let shared = try kp.exchange(peerPublicBytes: serverPub)
                let (c2sKey, s2cKey) = deriveSessionKeys(sharedSecret: shared)

                sendCipher = VPNCipher(key: c2sKey)
                recvCipher = VPNCipher(key: s2cKey)

                os_log("Key exchange OK! VPN active.", log: log, type: .info)
                onStatus?("VPN активен через UDP")
                onConnected?()
            } catch {
                onError?("Handshake error: \(error)")
            }
            return
        }

        // VPN packet — decrypt
        guard let cipher = recvCipher else { return }
        do {
            let plaintext = try cipher.decrypt(data)
            onPacket?(plaintext)
        } catch {
            os_log("Decrypt error: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    /// Send IP packet through VPN
    func sendPacket(_ packet: Data) {
        guard let cipher = sendCipher else { return }
        do {
            let encrypted = try cipher.encrypt(packet)
            connection?.send(content: encrypted, completion: .contentProcessed { _ in })
        } catch {
            os_log("Encrypt error", log: log, type: .error)
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }
}
