import Foundation
import os.log

#if canImport(WebRTC)
import WebRTC

/// Orchestrates the full MAX VPN Call pipeline:
/// MAX login → initiate call → signaling → WebRTC → DataChannel → key exchange → VPN tunnel
class MaxCallService: NSObject, @unchecked Sendable {

    // MARK: - Config

    struct Config {
        let maxToken: String
        let serverUserID: Int
        let serverPubkeyHex: String
        let deviceId: String
    }

    // MARK: - State

    enum State {
        case idle
        case loggingIn
        case calling
        case signaling
        case webrtcConnecting
        case keyExchange
        case vpnActive
        case failed(String)
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    var onStatusText: ((String) -> Void)?  // human-readable status for UI
    var onVPNPacket: ((Data) -> Void)?  // decrypted IP packets from server

    private let log = OSLog(subsystem: "com.swinter.vpn.tunnel", category: "maxcall")
    private let config: Config

    // MAX API WebSocket
    private var maxWS: URLSessionWebSocketTask?
    private var maxSeq = 0
    private var maxPending: [Int: (Result<[String: Any], Error>) -> Void] = [:]

    // Signaling WebSocket
    private var sigWS: URLSessionWebSocketTask?
    private var sigSeq = 0
    private var participantId: Int = 0

    // WebRTC
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var factory: RTCPeerConnectionFactory?

    private func getFactory() -> RTCPeerConnectionFactory {
        if let f = factory { return f }
        os_log("Initializing WebRTC factory...", log: log, type: .info)
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let f = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        factory = f
        os_log("WebRTC factory OK", log: log, type: .info)
        return f
    }

    // Crypto
    private var clientKeyPair: VPNKeyPair?
    private var sendCipher: VPNCipher?
    private var recvCipher: VPNCipher?

    // Continuations for async flow
    private var signalingReadyCont: CheckedContinuation<Void, Error>?
    private var webrtcConnectedCont: CheckedContinuation<Void, Error>?
    private var handshakeDoneCont: CheckedContinuation<Void, Error>?

    private var urlSession: URLSession!

    // MARK: - Init

    init(config: Config) {
        self.config = config
        super.init()
        self.urlSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Start the full VPN pipeline. Call from background thread.
    func start() async throws {
        os_log("start() called", log: log, type: .info)
        setStatus("MAX: вход...")
        setState(.loggingIn)

        // Step 1: Login to MAX
        try await maxLogin()
        setStatus("MAX: звоним боту...")

        // Step 2: Initiate call
        setState(.calling)
        let callParams = try await maxInitiateCall()
        setStatus("Signaling: подключение...")

        // Step 3: Connect signaling
        setState(.signaling)
        try await connectSignaling(callParams: callParams)
        setStatus("WebRTC: устанавливаем соединение...")

        // Step 4: Setup WebRTC + DataChannel + SDP offer
        setState(.webrtcConnecting)
        try await setupWebRTCAndOffer(callParams: callParams)

        setStatus("WebRTC: ожидание TURN relay...")
        // Step 5: Wait for WebRTC connection
        try await waitForWebRTCConnected()

        // Step 6: Key exchange
        setStatus("Crypto: обмен ключами X25519...")
        setState(.keyExchange)
        try await waitForHandshake()

        setStatus("VPN активен через MAX Call")
        setState(.vpnActive)
        os_log("VPN ACTIVE via MAX Call", log: log, type: .info)
    }

    /// Send an IP packet through the VPN tunnel (TUN → DataChannel)
    func sendPacket(_ packet: Data) {
        guard let cipher = sendCipher, let dc = dataChannel, dc.readyState == .open else { return }
        do {
            let encrypted = try cipher.encrypt(packet)
            dc.sendData(RTCDataBuffer(data: encrypted, isBinary: true))
        } catch {
            os_log("Encrypt error: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    func stop() {
        dataChannel?.close()
        peerConnection?.close()
        sigWS?.cancel(with: .goingAway, reason: nil)
        maxWS?.cancel(with: .goingAway, reason: nil)
        setState(.idle)
    }

    // MARK: - State

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
        switch s {
        case .failed(let msg):
            os_log("FAILED: %{public}@", log: log, type: .error, msg)
        default:
            os_log("State: %{public}@", log: log, type: .info, "\(s)")
        }
    }

    private func setStatus(_ text: String) {
        os_log("Status: %{public}@", log: log, type: .info, text)
        onStatusText?(text)
        // Also write to App Group so main app can read
        let defaults = UserDefaults(suiteName: "group.com.swinter.vpn")
        defaults?.set(text, forKey: "maxcall_status")
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Step 1: MAX API Login
    // ═══════════════════════════════════════════════════════════

    private func maxLogin() async throws {
        let url = URL(string: "wss://ws-api.oneme.ru/websocket")!
        var request = URLRequest(url: url)
        request.setValue("https://web.max.ru", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        maxWS = urlSession.webSocketTask(with: request)
        maxWS?.resume()
        startMaxRecvLoop()

        // Send INIT (opcode 6)
        let _ = try await maxRequest(opcode: 6, payload: [
            "userAgent": [
                "deviceType": "WEB",
                "locale": "en",
                "deviceLocale": "en",
                "osVersion": "macOS",
                "deviceName": "Chrome",
                "headerUserAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "appVersion": "26.3.7",
                "screen": "982x1512 2.0x",
                "timezone": "Asia/Barnaul",
            ],
            "deviceId": config.deviceId,
        ])

        // Send LOGIN (opcode 19)
        let loginResult = try await maxRequest(opcode: 19, payload: [
            "token": config.maxToken,
            "chatsCount": 40,
            "interactive": true,
            "chatsSync": 0,
            "contactsSync": 0,
            "presenceSync": -1,
            "draftsSync": 0,
        ])

        let uid = (loginResult["profile"] as? [String: Any])?["contact"] as? [String: Any]
        os_log("Logged in, uid=%{public}@", log: log, type: .info, "\(uid?["id"] ?? "?")")
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Step 2: Initiate Call (opcode 78)
    // ═══════════════════════════════════════════════════════════

    struct CallParams {
        let signalingURL: String
        let turnURLs: [String]
        let turnUsername: String
        let turnCredential: String
        let stunURLs: [String]
        let myInternalId: Int
        let conversationId: String
    }

    private func maxInitiateCall() async throws -> CallParams {
        let conversationId = UUID().uuidString.uppercased()
        let internalParams: [String: Any] = [
            "deviceId": config.deviceId,
            "sdkVersion": "2.8.10-beta.5",
            "clientAppKey": "CNHIJPLGDIHBABABA",
            "platform": "WEB",
            "protocolVersion": 5,
            "capabilities": "2A03F",
        ]
        let internalParamsJSON = String(data: try JSONSerialization.data(withJSONObject: internalParams), encoding: .utf8)!

        let result = try await maxRequest(opcode: 78, payload: [
            "conversationId": conversationId,
            "calleeIds": [config.serverUserID],
            "internalParams": internalParamsJSON,
            "isVideo": false,
        ])

        guard let callerParamsStr = result["internalCallerParams"] as? String,
              let callerParamsData = callerParamsStr.data(using: .utf8),
              let callerParams = try JSONSerialization.jsonObject(with: callerParamsData) as? [String: Any] else {
            throw MaxCallError.badCallResponse
        }

        var sigURL = callerParams["endpoint"] as? String ?? ""
        if !sigURL.contains("&platform=") {
            sigURL += "&platform=WEB&appVersion=1.1&version=5&device=browser&capabilities=2A03F&clientType=ONE_ME&tgt=start"
        }

        let turn = callerParams["turn"] as? [String: Any] ?? [:]
        let stun = callerParams["stun"] as? [String: Any] ?? [:]
        let idObj = callerParams["id"] as? [String: Any] ?? [:]
        let myInternalId: Int
        if let intId = idObj["internal"] as? Int {
            myInternalId = intId
        } else if let intId = idObj["internal"] as? Int64 {
            myInternalId = Int(intId)
        } else {
            myInternalId = 0
        }

        let turnURLsRaw = turn["urls"] as? [String] ?? (turn["urls"] as? String).map { [$0] } ?? []
        let stunURLsRaw = stun["urls"] as? [String] ?? (stun["urls"] as? String).map { [$0] } ?? []

        let convId = result["conversationId"] as? String ?? conversationId

        os_log("Call initiated. convId=%{public}@ internalId=%d", log: log, type: .info, convId, myInternalId)

        return CallParams(
            signalingURL: sigURL,
            turnURLs: turnURLsRaw,
            turnUsername: turn["username"] as? String ?? "",
            turnCredential: turn["credential"] as? String ?? "",
            stunURLs: stunURLsRaw,
            myInternalId: myInternalId,
            conversationId: convId
        )
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Step 3: Signaling WebSocket
    // ═══════════════════════════════════════════════════════════

    private func connectSignaling(callParams: CallParams) async throws {
        guard let url = URL(string: callParams.signalingURL) else {
            throw MaxCallError.badSignalingURL
        }

        var request = URLRequest(url: url)
        request.setValue("https://web.max.ru", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        sigWS = urlSession.webSocketTask(with: request)
        sigWS?.resume()
        startSigRecvLoop(myInternalId: callParams.myInternalId)

        // Wait for "connection" notification
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.signalingReadyCont = cont
        }

        os_log("Signaling connected, participantId=%d", log: log, type: .info, participantId)
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Step 4: WebRTC + DataChannel + SDP Offer
    // ═══════════════════════════════════════════════════════════

    private func setupWebRTCAndOffer(callParams: CallParams) async throws {
        // ICE servers: MAX TURN + our own TURN on VPS
        var iceServers: [RTCIceServer] = []
        if !callParams.stunURLs.isEmpty {
            iceServers.append(RTCIceServer(urlStrings: callParams.stunURLs))
        }
        if !callParams.turnURLs.isEmpty {
            iceServers.append(RTCIceServer(
                urlStrings: callParams.turnURLs,
                username: callParams.turnUsername,
                credential: callParams.turnCredential
            ))
        }
        // Only MAX TURN servers — VPS coturn unreachable from restricted network

        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = iceServers
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.continualGatheringPolicy = .gatherContinually
        // No relay-only — let iOS send direct STUN checks to VPS host candidate

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        peerConnection = getFactory().peerConnection(with: rtcConfig, constraints: constraints, delegate: self)

        // Add silent audio track (required for call to work)
        let audioSource = getFactory().audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil
        ))
        let audioTrack = getFactory().audioTrack(with: audioSource, trackId: "audio0")
        audioTrack.isEnabled = false // silent
        peerConnection?.add(audioTrack, streamIds: ["stream0"])

        // Create DataChannel "vpn" BEFORE SDP offer
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        dataChannel = peerConnection?.dataChannel(forLabel: "vpn", configuration: dcConfig)
        dataChannel?.delegate = self
        os_log("DataChannel 'vpn' created", log: log, type: .info)

        // Prepare key pair for handshake
        clientKeyPair = VPNKeyPair()

        // Create and send SDP offer
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil
        )

        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection?.offer(for: offerConstraints) { sdp, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let sdp = sdp {
                    cont.resume(returning: sdp)
                } else {
                    cont.resume(throwing: MaxCallError.sdpFailed)
                }
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peerConnection?.setLocalDescription(offer) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }

        // Send offer via signaling
        sigSeq += 1
        let offerMsg: [String: Any] = [
            "command": "transmit-data",
            "sequence": sigSeq,
            "participantId": participantId,
            "data": [
                "sdp": [
                    "type": "offer",
                    "sdp": offer.sdp,
                ]
            ],
            "participantType": "USER",
        ]
        let offerData = try JSONSerialization.data(withJSONObject: offerMsg)
        sigWS?.send(.string(String(data: offerData, encoding: .utf8)!)) { _ in }

        os_log("SDP offer sent", log: log, type: .info)
    }

    private func waitForWebRTCConnected() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if peerConnection?.connectionState == .connected {
                cont.resume()
            } else {
                webrtcConnectedCont = cont
            }
        }
    }

    private func waitForHandshake() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if sendCipher != nil {
                cont.resume()
            } else {
                handshakeDoneCont = cont
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - MAX API WebSocket Protocol
    // ═══════════════════════════════════════════════════════════

    private func maxRequest(opcode: Int, payload: [String: Any]) async throws -> [String: Any] {
        let seq = maxSeq
        maxSeq += 1

        let msg: [String: Any] = [
            "ver": 11,
            "cmd": 0,
            "seq": seq,
            "opcode": opcode,
            "payload": payload,
        ]

        let data = try JSONSerialization.data(withJSONObject: msg)
        let str = String(data: data, encoding: .utf8)!

        return try await withCheckedThrowingContinuation { cont in
            maxPending[seq] = { result in
                switch result {
                case .success(let payload):
                    cont.resume(returning: payload)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            maxWS?.send(.string(str)) { [weak self] error in
                if let error = error {
                    self?.maxPending.removeValue(forKey: seq)?(.failure(error))
                }
            }
        }
    }

    private func startMaxRecvLoop() {
        maxWS?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handleMaxMessage(message)
                self.startMaxRecvLoop() // continue receiving
            case .failure(let error):
                os_log("MAX WS error: %{public}@", log: self.log, type: .error, error.localizedDescription)
            }
        }
    }

    private func handleMaxMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let cmd = json["cmd"] as? Int ?? -1
        let seq = json["seq"] as? Int ?? -1
        let payload = json["payload"] as? [String: Any] ?? [:]

        if cmd == 1 && maxPending[seq] != nil { // RESPONSE
            maxPending.removeValue(forKey: seq)?(.success(payload))
        } else if cmd == 3 && maxPending[seq] != nil { // ERROR
            maxPending.removeValue(forKey: seq)?(.failure(MaxCallError.apiError(payload)))
        }
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Signaling WebSocket Protocol
    // ═══════════════════════════════════════════════════════════

    private func startSigRecvLoop(myInternalId: Int) {
        sigWS?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handleSigMessage(message, myInternalId: myInternalId)
                self.startSigRecvLoop(myInternalId: myInternalId)
            case .failure(let error):
                os_log("Sig WS error: %{public}@", log: self.log, type: .error, error.localizedDescription)
            }
        }
    }

    private func handleSigMessage(_ message: URLSessionWebSocketTask.Message, myInternalId: Int) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }

        // Handle ping/pong
        if text == "ping" {
            sigWS?.send(.string("pong")) { _ in }
            return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let notification = json["notification"] as? String

        if notification == "connection" {
            // Extract remote participant ID
            let conv = json["conversation"] as? [String: Any] ?? [:]
            let participants = conv["participants"] as? [[String: Any]] ?? []
            for p in participants {
                let pId = (p["id"] as? Int) ?? Int(p["id"] as? Int64 ?? 0)
                if pId != 0 && pId != myInternalId {
                    participantId = pId
                }
            }
            signalingReadyCont?.resume()
            signalingReadyCont = nil
            os_log("Signaling: connection notification", log: log, type: .info)

        } else if notification == "transmitted-data" {
            let msgData = json["data"] as? [String: Any] ?? [:]
            handleRemoteSDP(msgData)

        } else if notification == "accepted-call" {
            os_log("Signaling: call accepted", log: log, type: .info)

        } else if notification == "participant-left" || notification == "conversation-destroyed" {
            os_log("Signaling: call ended", log: log, type: .info)
            stop()
        }
    }

    private func handleRemoteSDP(_ data: [String: Any]) {
        if let sdpDict = data["sdp"] as? [String: Any],
           let type = sdpDict["type"] as? String,
           let sdpStr = sdpDict["sdp"] as? String {

            os_log("Received SDP %{public}@", log: log, type: .info, type)

            let sdpType: RTCSdpType = type == "answer" ? .answer : .offer
            let sdp = RTCSessionDescription(type: sdpType, sdp: sdpStr)

            peerConnection?.setRemoteDescription(sdp) { [weak self] error in
                if let error = error {
                    os_log("setRemoteDescription error: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                } else {
                    os_log("Remote SDP set OK", log: self?.log ?? .default, type: .info)
                }
            }
        }

        if let candidate = data["candidate"] as? [String: Any],
           let candidateStr = candidate["candidate"] as? String,
           !candidateStr.isEmpty {
            let sdpMid = candidate["sdpMid"] as? String ?? "0"
            let sdpMLineIndex = candidate["sdpMLineIndex"] as? Int32 ?? 0
            let iceCandidate = RTCIceCandidate(sdp: candidateStr, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            peerConnection?.add(iceCandidate) { error in
                if let error = error {
                    os_log("addIceCandidate error: %{public}@", type: .error, error.localizedDescription)
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - DataChannel Handshake
    // ═══════════════════════════════════════════════════════════

    private func handleDataChannelOpen() {
        guard let kp = clientKeyPair else { return }
        os_log("DataChannel open, sending handshake", log: log, type: .info)
        let hello = buildHandshakeMsg(publicBytes: kp.publicBytes)
        dataChannel?.sendData(RTCDataBuffer(data: hello, isBinary: true))
    }

    private func handleDataChannelMessage(_ data: Data) {
        // Key exchange not done yet → this is server's handshake
        if sendCipher == nil {
            do {
                let serverPub = try parseHandshakeMsg(data)
                let expectedPub = Data(hexString: config.serverPubkeyHex)

                guard serverPub == expectedPub else {
                    os_log("SERVER KEY MISMATCH!", log: log, type: .error)
                    handshakeDoneCont?.resume(throwing: VPNCryptoError.keyMismatch)
                    handshakeDoneCont = nil
                    return
                }

                guard let kp = clientKeyPair else { return }
                let shared = try kp.exchange(peerPublicBytes: serverPub)
                let (c2sKey, s2cKey) = deriveSessionKeys(sharedSecret: shared)

                sendCipher = VPNCipher(key: c2sKey)
                recvCipher = VPNCipher(key: s2cKey)

                os_log("Key exchange OK! VPN active.", log: log, type: .info)
                handshakeDoneCont?.resume()
                handshakeDoneCont = nil

            } catch {
                os_log("Handshake error: %{public}@", log: log, type: .error, error.localizedDescription)
                handshakeDoneCont?.resume(throwing: error)
                handshakeDoneCont = nil
            }
            return
        }

        // VPN packet from server → decrypt → forward to TUN
        guard let cipher = recvCipher else { return }
        do {
            let plaintext = try cipher.decrypt(data)
            onVPNPacket?(plaintext)
        } catch {
            os_log("Decrypt error: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension MaxCallService: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        os_log("Signaling state: %d", log: log, type: .info, stateChanged.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        os_log("ICE connection: %d", log: log, type: .info, newState.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        os_log("ICE gathering: %d", log: log, type: .info, newState.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Send ICE candidate via signaling
        sigSeq += 1
        let msg: [String: Any] = [
            "command": "transmit-data",
            "sequence": sigSeq,
            "participantId": participantId,
            "data": [
                "candidate": [
                    "candidate": candidate.sdp,
                    "sdpMid": candidate.sdpMid ?? "0",
                    "sdpMLineIndex": candidate.sdpMLineIndex,
                    "usernameFragment": "",
                ]
            ],
            "participantType": "USER",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            sigWS?.send(.string(str)) { _ in }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        os_log("Remote DataChannel opened: %{public}@", log: log, type: .info, dataChannel.label)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        os_log("PeerConnection state: %d", log: log, type: .info, newState.rawValue)
        if newState == .connected {
            webrtcConnectedCont?.resume()
            webrtcConnectedCont = nil
        } else if newState == .failed || newState == .disconnected || newState == .closed {
            webrtcConnectedCont?.resume(throwing: MaxCallError.webrtcFailed)
            webrtcConnectedCont = nil
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension MaxCallService: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        os_log("DataChannel state: %d", log: log, type: .info, dataChannel.readyState.rawValue)
        if dataChannel.readyState == .open {
            handleDataChannelOpen()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        handleDataChannelMessage(buffer.data)
    }
}

// MARK: - Errors

enum MaxCallError: Error, LocalizedError {
    case badCallResponse
    case badSignalingURL
    case sdpFailed
    case webrtcFailed
    case apiError([String: Any])

    var errorDescription: String? {
        switch self {
        case .badCallResponse: return "Bad call initiation response"
        case .badSignalingURL: return "Invalid signaling URL"
        case .sdpFailed: return "SDP creation failed"
        case .webrtcFailed: return "WebRTC connection failed"
        case .apiError(let p): return "MAX API error: \(p)"
        }
    }
}

#endif // canImport(WebRTC)

// MARK: - Data hex helper (used by UDPVPNClient too, must be outside #if)

extension Data {
    init(hexString: String) {
        self.init()
        var hex = hexString
        while hex.count >= 2 {
            let byteStr = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let byte = UInt8(byteStr, radix: 16) {
                append(byte)
            }
        }
    }
}
