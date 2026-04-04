import Foundation
import CryptoKit

// MARK: - Constants

let handshakeMagic = Data("MAXVPN01".utf8)
let vpnKeySize = 32
let vpnNonceSize = 12

// MARK: - X25519 Key Pair

struct VPNKeyPair {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Curve25519.KeyAgreement.PublicKey

    init() {
        self.privateKey = .init()
        self.publicKey = privateKey.publicKey
    }

    var publicBytes: Data {
        publicKey.rawRepresentation
    }

    func exchange(peerPublicBytes: Data) throws -> Data {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicBytes)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        return shared.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Key Derivation

/// Derives (client→server key, server→client key) from shared secret via HKDF.
func deriveSessionKeys(sharedSecret: Data) -> (c2sKey: SymmetricKey, s2cKey: SymmetricKey) {
    let salt = Data("maxvpn".utf8)
    let info = Data("maxvpn-session-keys".utf8)

    let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: sharedSecret), salt: salt)
    let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: vpnKeySize * 2)

    let okmBytes = okm.withUnsafeBytes { Data($0) }
    let c2sKey = SymmetricKey(data: okmBytes[0..<vpnKeySize])
    let s2cKey = SymmetricKey(data: okmBytes[vpnKeySize..<vpnKeySize*2])
    return (c2sKey, s2cKey)
}

// MARK: - Handshake Messages

func buildHandshakeMsg(publicBytes: Data) -> Data {
    return handshakeMagic + publicBytes
}

func parseHandshakeMsg(_ data: Data) throws -> Data {
    guard data.count >= handshakeMagic.count + 32 else {
        throw VPNCryptoError.badHandshake
    }
    guard data.prefix(handshakeMagic.count) == handshakeMagic else {
        throw VPNCryptoError.badMagic
    }
    return data.suffix(from: handshakeMagic.count)
}

// MARK: - VPN Cipher (ChaCha20-Poly1305)

class VPNCipher {
    private let key: SymmetricKey
    private var sendCounter: UInt32 = 0
    private var recvCounter: UInt32 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Encrypt: returns [4-byte BE counter][ciphertext + 16-byte tag]
    func encrypt(_ plaintext: Data) throws -> Data {
        let counter = sendCounter
        sendCounter += 1

        let nonce = makeNonce(counter)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

        var result = Data(capacity: 4 + sealed.ciphertext.count + sealed.tag.count)
        var be = counter.bigEndian
        result.append(Data(bytes: &be, count: 4))
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    /// Decrypt: expects [4-byte BE counter][ciphertext + 16-byte tag]
    func decrypt(_ data: Data) throws -> Data {
        guard data.count >= 4 + 16 else {
            throw VPNCryptoError.packetTooShort
        }

        let counter = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        // Anti-replay window
        if counter + 1000 < recvCounter {
            throw VPNCryptoError.replay
        }

        let nonce = makeNonce(counter)
        let payload = data.suffix(from: 4)
        let ciphertext = payload.prefix(payload.count - 16)
        let tag = payload.suffix(16)

        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try ChaChaPoly.open(sealedBox, using: key)

        if counter >= recvCounter {
            recvCounter = counter + 1
        }

        return plaintext
    }

    private func makeNonce(_ counter: UInt32) -> ChaChaPoly.Nonce {
        // 12-byte nonce: [8 zero bytes][4-byte counter BE]
        var nonceBytes = Data(repeating: 0, count: 8)
        var be = counter.bigEndian
        nonceBytes.append(Data(bytes: &be, count: 4))
        return try! ChaChaPoly.Nonce(data: nonceBytes)
    }
}

enum VPNCryptoError: Error, LocalizedError {
    case badHandshake
    case badMagic
    case packetTooShort
    case replay
    case keyMismatch

    var errorDescription: String? {
        switch self {
        case .badHandshake: return "Bad handshake message"
        case .badMagic: return "Bad magic bytes"
        case .packetTooShort: return "Packet too short"
        case .replay: return "Replay detected"
        case .keyMismatch: return "Server key mismatch (possible MITM)"
        }
    }
}
