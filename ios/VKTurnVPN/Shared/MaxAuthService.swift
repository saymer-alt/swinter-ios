import Foundation
import Network
import os.log

/// SMS-авторизация в MAX через бинарный TCP протокол.
/// Транспорт: TCP+TLS к api.oneme.ru:443, формат: 10-byte header + MessagePack payload.
/// deviceType=ANDROID обязателен (WEB блокирует SMS auth).
class MaxAuthService: @unchecked Sendable {

    static let shared = MaxAuthService()

    private let log = OSLog(subsystem: "com.swinter.vpn", category: "maxauth")
    private let host = "api.oneme.ru"
    private let port: UInt16 = 443
    private let appGroup = "group.com.swinter.vpn"

    static let tokenKey = "max_auth_token"
    static let phoneKey = "max_auth_phone"
    static let userIdKey = "max_auth_userid"
    static let userNameKey = "max_auth_username"

    private var connection: NWConnection?
    private var seq: Int16 = 0

    // MARK: - Public API

    func requestCode(phone: String) async throws -> (verifyToken: String, codeLength: Int) {
        try await connect()

        // SESSION_INIT (opcode 6)
        let _ = try await sendAndRecv(opcode: 6, payload: [
            "userAgent": MsgPack.map([
                "deviceType": .str("ANDROID"),
                "locale": .str("ru"),
                "appVersion": .str("26.11.0"),
            ]),
            "deviceId": .str(UUID().uuidString),
        ])

        // AUTH_REQUEST (opcode 17)
        let (cmd, raw) = try await sendAndRecv(opcode: 17, payload: [
            "phone": .str(phone),
            "type": .str("START_AUTH"),
        ])

        guard cmd == 1 else {
            let err = parseErrorMessage(raw)
            // Check for rate limit
            if raw.contains("limit.violate".data(using: .ascii)!) {
                throw MaxAuthError.serverError("Слишком много попыток. Подождите несколько минут.")
            }
            throw MaxAuthError.serverError(err)
        }

        guard let token = findLongToken(raw) else {
            throw MaxAuthError.noVerifyToken
        }

        let codeLength = findIntField(raw, key: "codeLength") ?? 6
        os_log("AUTH_REQUEST OK, codeLength=%d", log: log, type: .info, codeLength)
        return (token, codeLength)
    }

    /// Result of confirmCode: either a token (login done) or a 2FA challenge
    enum ConfirmResult {
        case token(String)
        case passwordChallenge(trackId: String, email: String, hint: String)
    }

    func confirmCode(verifyToken: String, code: String) async throws -> ConfirmResult {
        let (cmd, raw) = try await sendAndRecv(opcode: 18, payload: [
            "token": .str(verifyToken),
            "verifyCode": .str(code),
            "authTokenType": .str("CHECK_CODE"),
        ])

        guard cmd == 1 else {
            let err = parseErrorMessage(raw)
            if raw.contains("code.wrong".data(using: .ascii)!) {
                throw MaxAuthError.serverError("Неверный код. Проверьте и попробуйте снова.")
            }
            if raw.contains("limit.violate".data(using: .ascii)!) {
                throw MaxAuthError.serverError("Слишком много попыток. Подождите несколько минут.")
            }
            throw MaxAuthError.serverError(err)
        }

        os_log("AUTH_CONFIRM cmd=1, payload=%d bytes, hex=%{public}@", log: log, type: .info, raw.count, raw.prefix(100).map { String(format: "%02x", $0) }.joined())

        // Check if it's a REGISTER response (account doesn't exist)
        if raw.contains("REGISTER".data(using: .ascii)!) {
            throw MaxAuthError.serverError("Аккаунт не найден на этом номере. Нужна регистрация в MAX.")
        }

        // Check for 2FA passwordChallenge
        if raw.contains("passwordChallenge".data(using: .ascii)!) {
            let trackId = findStringField(raw, key: "trackId") ?? ""
            let email = findStringField(raw, key: "email") ?? ""
            let hint = findStringField(raw, key: "hint") ?? ""
            os_log("2FA required, trackId=%{public}@, email=%{public}@", log: log, type: .info, trackId, email)
            return .passwordChallenge(trackId: trackId, email: email, hint: hint)
        }

        guard let authToken = findLongToken(raw) else {
            os_log("No long token found in %d bytes", log: log, type: .error, raw.count)
            throw MaxAuthError.noAuthToken
        }

        os_log("AUTH_CONFIRM OK, token length=%d", log: log, type: .info, authToken.count)
        return .token(authToken)
    }

    /// Submit 2FA password (opcode 115 = PASSWORD_AUTH)
    func submitPassword(trackId: String, password: String) async throws -> String {
        let (cmd, raw) = try await sendAndRecv(opcode: 115, payload: [
            "trackId": .str(trackId),
            "password": .str(password),
        ])

        guard cmd == 1 else {
            let err = parseErrorMessage(raw)
            if raw.contains("password.wrong".data(using: .ascii)!) ||
               raw.contains("wrong.password".data(using: .ascii)!) {
                throw MaxAuthError.serverError("Неверный пароль. Попробуйте снова.")
            }
            throw MaxAuthError.serverError(err)
        }

        guard let authToken = findLongToken(raw) else {
            os_log("No token after PASSWORD_AUTH, %d bytes", log: log, type: .error, raw.count)
            throw MaxAuthError.noAuthToken
        }

        os_log("PASSWORD_AUTH OK, token length=%d", log: log, type: .info, authToken.count)
        return authToken
    }

    func login(token: String, phone: String) async throws {
        if connection == nil {
            try await connect()
            let _ = try await sendAndRecv(opcode: 6, payload: [
                "userAgent": MsgPack.map([
                    "deviceType": .str("ANDROID"),
                    "locale": .str("ru"),
                    "appVersion": .str("26.11.0"),
                ]),
                "deviceId": .str(UUID().uuidString),
            ])
        }

        let (cmd, raw) = try await sendAndRecv(opcode: 19, payload: [
            "token": .str(token),
            "chatsCount": .int(0),
            "interactive": .bool(false),
        ])

        guard cmd == 1 else {
            let err = parseErrorMessage(raw)
            throw MaxAuthError.serverError(err)
        }

        os_log("LOGIN OK", log: log, type: .info)

        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(token, forKey: Self.tokenKey)
        defaults?.set(phone, forKey: Self.phoneKey)

        disconnect()
    }

    func fullLogin(phone: String, code: String, verifyToken: String) async throws -> ConfirmResult {
        let result = try await confirmCode(verifyToken: verifyToken, code: code)
        switch result {
        case .token(let authToken):
            try await login(token: authToken, phone: phone)
            return result
        case .passwordChallenge:
            return result
        }
    }

    func fullLoginWith2FA(phone: String, trackId: String, password: String) async throws {
        let authToken = try await submitPassword(trackId: trackId, password: password)
        try await login(token: authToken, phone: phone)
    }

    func logout() {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.removeObject(forKey: Self.tokenKey)
        defaults?.removeObject(forKey: Self.phoneKey)
        defaults?.removeObject(forKey: Self.userIdKey)
        defaults?.removeObject(forKey: Self.userNameKey)
        disconnect()
    }

    var isLoggedIn: Bool {
        let token = UserDefaults(suiteName: appGroup)?.string(forKey: Self.tokenKey)
        return token != nil && !(token?.isEmpty ?? true)
    }

    var savedToken: String? { UserDefaults(suiteName: appGroup)?.string(forKey: Self.tokenKey) }
    var savedPhone: String? { UserDefaults(suiteName: appGroup)?.string(forKey: Self.phoneKey) }
    var savedUserName: String? { UserDefaults(suiteName: appGroup)?.string(forKey: Self.userNameKey) }
    var savedUserId: String? { UserDefaults(suiteName: appGroup)?.string(forKey: Self.userIdKey) }

    var maskedPhone: String {
        guard let phone = savedPhone, phone.count > 4 else { return "" }
        return "\(phone.prefix(2))***\(phone.suffix(4))"
    }

    // MARK: - TCP Connection

    private func connect() async throws {
        seq = 0
        let tlsParams = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsParams.securityProtocolOptions, { _, _, completionHandler in
            completionHandler(true) // Skip cert verification (like Python verify=False)
        }, DispatchQueue.global())

        let params = NWParameters(tls: tlsParams, tcp: NWProtocolTCP.Options())
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let conn = NWConnection(to: endpoint, using: params)

        connection = conn
        conn.start(queue: DispatchQueue.global())

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error):
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: MaxAuthError.connectionFailed)
                default:
                    break
                }
            }
        }

        os_log("TCP connected to %{public}@:%d", log: log, type: .info, host, port)
    }

    private func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Binary Protocol

    private func sendAndRecv(opcode: Int16, payload: [String: MsgPackValue]) async throws -> (Int8, Data) {
        guard let conn = connection else { throw MaxAuthError.connectionFailed }

        let payloadBytes = MsgPack.encodeMap(payload)
        let currentSeq = seq
        seq += 1

        // Header: ver(1) + cmd(1) + seq(2 BE) + opcode(2 BE) + length(4 BE)
        var header = Data(count: 10)
        header[0] = 10 // ver
        header[1] = 0  // cmd = request
        header[2] = UInt8((UInt16(bitPattern: currentSeq) >> 8) & 0xFF)
        header[3] = UInt8(UInt16(bitPattern: currentSeq) & 0xFF)
        header[4] = UInt8((UInt16(bitPattern: opcode) >> 8) & 0xFF)
        header[5] = UInt8(UInt16(bitPattern: opcode) & 0xFF)
        let len = UInt32(payloadBytes.count)
        header[6] = UInt8((len >> 24) & 0xFF)
        header[7] = UInt8((len >> 16) & 0xFF)
        header[8] = UInt8((len >> 8) & 0xFF)
        header[9] = UInt8(len & 0xFF)

        let packet = header + payloadBytes

        os_log("SEND opcode=%d seq=%d payload=%d bytes", log: log, type: .info, opcode, currentSeq, payloadBytes.count)

        // Send
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: packet, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }

        // Receive 10-byte header
        let respHeader = try await recvExact(conn: conn, length: 10)
        let respCmd = Int8(bitPattern: respHeader[1])
        let respLen = (Int(respHeader[6]) << 24) | (Int(respHeader[7]) << 16) | (Int(respHeader[8]) << 8) | Int(respHeader[9])
        let payloadLen = respLen & 0x00FFFFFF

        os_log("RECV cmd=%d payloadLen=%d", log: log, type: .info, respCmd, payloadLen)

        // Receive payload
        var respPayload = Data()
        if payloadLen > 0 {
            respPayload = try await recvExact(conn: conn, length: payloadLen)
        }

        return (respCmd, respPayload)
    }

    private func recvExact(conn: NWConnection, length: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < length {
            let remaining = length - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: MaxAuthError.connectionFailed)
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }

    // MARK: - Response Parsing

    /// Find the longest base64url-like string (auth token) in raw response
    private func findLongToken(_ data: Data) -> String? {
        // Token chars: base64url + possible dots, tildes etc
        let validChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-+.~=".unicodeScalars.map { UInt8(ascii: $0) })
        var best: String?
        var current = Data()

        for byte in data {
            if validChars.contains(byte) {
                current.append(byte)
            } else {
                if current.count > 100, let s = String(data: current, encoding: .ascii) {
                    if best == nil || s.count > best!.count {
                        best = s
                    }
                }
                current = Data()
            }
        }
        if current.count > 100, let s = String(data: current, encoding: .ascii) {
            if best == nil || s.count > best!.count {
                best = s
            }
        }
        return best
    }

    /// Find a string value after a given key in msgpack-ish data
    private func findStringField(_ data: Data, key: String) -> String? {
        guard let keyData = key.data(using: .utf8) else { return nil }
        guard let range = data.range(of: keyData) else { return nil }
        let afterKey = range.upperBound
        guard afterKey < data.count else { return nil }
        let byte = data[afterKey]
        var strLen = 0
        var strStart = afterKey + 1
        if byte & 0xE0 == 0xA0 { // fixstr
            strLen = Int(byte & 0x1F)
        } else if byte == 0xD9 && strStart < data.count { // str8
            strLen = Int(data[strStart])
            strStart += 1
        } else if byte == 0xDA && strStart + 1 < data.count { // str16
            strLen = Int(data[strStart]) << 8 | Int(data[strStart + 1])
            strStart += 2
        }
        guard strLen > 0 && strStart + strLen <= data.count else { return nil }
        return String(data: data[strStart..<(strStart + strLen)], encoding: .utf8)
    }

    /// Find an integer value after a given key in msgpack-ish data
    private func findIntField(_ data: Data, key: String) -> Int? {
        guard let keyData = key.data(using: .utf8) else { return nil }
        guard let range = data.range(of: keyData) else { return nil }
        let afterKey = range.upperBound
        if afterKey < data.count {
            let byte = data[afterKey]
            if byte <= 0x7f { return Int(byte) } // positive fixint
        }
        return nil
    }

    /// Extract error message from error response
    private func parseErrorMessage(_ data: Data) -> String {
        // Look for common error keys
        for key in ["localizedMessage", "message", "error", "title"] {
            if let keyData = key.data(using: .utf8),
               let range = data.range(of: keyData) {
                let afterKey = range.upperBound
                if afterKey < data.count {
                    // Next msgpack object should be a string
                    let byte = data[afterKey]
                    var strLen = 0
                    var strStart = afterKey + 1
                    if byte & 0xE0 == 0xA0 { // fixstr
                        strLen = Int(byte & 0x1F)
                    } else if byte == 0xd9 && strStart < data.count { // str8
                        strLen = Int(data[strStart])
                        strStart += 1
                    } else if byte == 0xda && strStart + 1 < data.count { // str16
                        strLen = Int(data[strStart]) << 8 | Int(data[strStart + 1])
                        strStart += 2
                    }
                    if strLen > 0 && strStart + strLen <= data.count {
                        let strData = data[strStart..<(strStart + strLen)]
                        if let s = String(data: strData, encoding: .utf8), !s.isEmpty {
                            return s
                        }
                    }
                }
            }
        }
        return "Неизвестная ошибка сервера"
    }
}

// MARK: - Minimal MessagePack Encoder

enum MsgPackValue {
    case str(String)
    case int(Int)
    case bool(Bool)
    case map([String: MsgPackValue])
}

struct MsgPack {
    static func map(_ m: [String: MsgPackValue]) -> MsgPackValue { .map(m) }

    static func encodeMap(_ map: [String: MsgPackValue]) -> Data {
        var out = Data()
        let count = map.count
        if count < 16 {
            out.append(UInt8(0x80 | count)) // fixmap
        } else {
            out.append(0xDE) // map16
            out.append(UInt8((count >> 8) & 0xFF))
            out.append(UInt8(count & 0xFF))
        }
        for (key, value) in map {
            encodeString(key, to: &out)
            encodeValue(value, to: &out)
        }
        return out
    }

    static func encodeValue(_ value: MsgPackValue, to out: inout Data) {
        switch value {
        case .str(let s):
            encodeString(s, to: &out)
        case .int(let i):
            encodeInt(i, to: &out)
        case .bool(let b):
            out.append(b ? 0xC3 : 0xC2)
        case .map(let m):
            let mapData = encodeMap(m)
            out.append(mapData)
        }
    }

    static func encodeString(_ s: String, to out: inout Data) {
        let bytes = Array(s.utf8)
        let len = bytes.count
        if len < 32 {
            out.append(UInt8(0xA0 | len)) // fixstr
        } else if len < 256 {
            out.append(0xD9) // str8
            out.append(UInt8(len))
        } else if len < 65536 {
            out.append(0xDA) // str16
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(0xDB) // str32
            out.append(UInt8((len >> 24) & 0xFF))
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        }
        out.append(contentsOf: bytes)
    }

    static func encodeInt(_ i: Int, to out: inout Data) {
        if i >= 0 && i <= 127 {
            out.append(UInt8(i)) // positive fixint
        } else if i >= -32 && i < 0 {
            out.append(UInt8(bitPattern: Int8(i))) // negative fixint
        } else if i >= 0 && i <= 0xFF {
            out.append(0xCC) // uint8
            out.append(UInt8(i))
        } else if i >= 0 && i <= 0xFFFF {
            out.append(0xCD) // uint16
            out.append(UInt8((i >> 8) & 0xFF))
            out.append(UInt8(i & 0xFF))
        } else if i >= 0 {
            out.append(0xCE) // uint32
            out.append(UInt8((i >> 24) & 0xFF))
            out.append(UInt8((i >> 16) & 0xFF))
            out.append(UInt8((i >> 8) & 0xFF))
            out.append(UInt8(i & 0xFF))
        } else {
            out.append(0xD2) // int32
            let u = UInt32(bitPattern: Int32(i))
            out.append(UInt8((u >> 24) & 0xFF))
            out.append(UInt8((u >> 16) & 0xFF))
            out.append(UInt8((u >> 8) & 0xFF))
            out.append(UInt8(u & 0xFF))
        }
    }
}

// MARK: - Errors

enum MaxAuthError: Error, LocalizedError {
    case noVerifyToken
    case noAuthToken
    case serverError(String)
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .noVerifyToken: return "Сервер не вернул verifyToken"
        case .noAuthToken: return "Не удалось получить токен авторизации"
        case .serverError(let msg): return msg
        case .connectionFailed: return "Не удалось подключиться к MAX"
        }
    }
}
