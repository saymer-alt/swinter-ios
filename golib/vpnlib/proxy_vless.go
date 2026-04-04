package vpnlib

// Swinger — VLESS client using sing-vmess library
// Supports: TCP, TLS, Reality (via uTLS), Vision flow

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/hkdf"

	utls "github.com/metacubex/utls"
	xutls "github.com/refraction-networking/utls"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing-vmess/vless"
)

type VLESSDialer struct {
	server         string
	uuid           [16]byte
	client         *vless.Client
	tlsMode        string
	sni            string
	fingerprint    string
	realityPubKey  []byte
	realityShortID []byte
	transport      string // tcp, ws
	wsPath         string
}

func NewVLESSDialer(sc ServerConfig) (*VLESSDialer, error) {
	if sc.VLESS == nil {
		return nil, fmt.Errorf("VLESS config missing")
	}
	v := sc.VLESS

	// Parse UUID for manual VLESS header (Reality mode)
	uuid, err := parseUUID(v.UUID)
	if err != nil {
		return nil, fmt.Errorf("bad UUID: %w", err)
	}

	// Logger is required for Vision flow (nil causes crash)
	client, err := vless.NewClient(v.UUID, v.Flow, nopLogger{})
	if err != nil {
		return nil, fmt.Errorf("create VLESS client: %w", err)
	}

	// Parse Reality public key
	var pubKey []byte
	if v.RealityPublicKey != "" {
		key := strings.NewReplacer("-", "+", "_", "/").Replace(v.RealityPublicKey)
		for len(key)%4 != 0 {
			key += "="
		}
		pubKey, _ = base64.StdEncoding.DecodeString(key)
		if len(pubKey) == 0 {
			pubKey, _ = hex.DecodeString(v.RealityPublicKey)
		}
	}

	var shortID []byte
	if v.RealityShortID != "" {
		shortID, _ = hex.DecodeString(v.RealityShortID)
	}

	sni := v.SNI
	if sni == "" {
		sni, _, _ = net.SplitHostPort(sc.Address)
	}

	transport := v.Transport
	if transport == "" {
		transport = "tcp"
	}

	return &VLESSDialer{
		server:         sc.Address,
		uuid:           uuid,
		client:         client,
		tlsMode:        v.TLS,
		sni:            sni,
		fingerprint:    v.Fingerprint,
		realityPubKey:  pubKey,
		realityShortID: shortID,
		transport:      transport,
		wsPath:         v.WSPath,
	}, nil
}

func (d *VLESSDialer) Protocol() string { return "vless" }
func (d *VLESSDialer) Close() error     { return nil }

func (d *VLESSDialer) DialTCP(ctx context.Context, destAddr string) (net.Conn, error) {
	log.Printf("[vless] DialTCP %s via %s (tls=%s)", destAddr, d.server, d.tlsMode)

	dialer := &net.Dialer{Timeout: 10 * time.Second}

	// 1. TCP connect to server
	rawConn, err := dialer.DialContext(ctx, "tcp", d.server)
	if err != nil {
		return nil, fmt.Errorf("tcp connect: %w", err)
	}

	// 2. TLS handshake
	var tlsConn net.Conn
	switch d.tlsMode {
	case "reality":
		tlsConn, err = d.doReality(ctx, rawConn)
		if err != nil {
			rawConn.Close()
			return nil, fmt.Errorf("reality: %w", err)
		}
	case "tls":
		tlsConn, err = d.doTLS(ctx, rawConn)
		if err != nil {
			rawConn.Close()
			return nil, fmt.Errorf("tls: %w", err)
		}
	default:
		tlsConn = rawConn
	}

	// 2.5. WebSocket upgrade (if ws transport)
	if d.transport == "ws" {
		tlsConn, err = wsUpgrade(tlsConn, d.sni, d.wsPath)
		if err != nil {
			tlsConn.Close()
			return nil, fmt.Errorf("ws upgrade: %w", err)
		}
	}

	// 3. VLESS protocol
	if d.tlsMode == "reality" {
		// For Reality: use manual VLESS header (no sing-vmess Vision, avoids type mismatch)
		host, portStr, _ := net.SplitHostPort(destAddr)
		port := 0
		fmt.Sscanf(portStr, "%d", &port)
		header := buildVLESSHeader(d.uuid, host, uint16(port))
		if _, err := tlsConn.Write(header); err != nil {
			tlsConn.Close()
			return nil, fmt.Errorf("write vless header: %w", err)
		}
		return &vlessRawConn{Conn: tlsConn}, nil
	}

	// For TLS: use sing-vmess (supports Vision flow)
	dest := M.ParseSocksaddr(destAddr)
	vlessConn, err := d.client.DialConn(tlsConn, dest)
	if err != nil {
		tlsConn.Close()
		return nil, fmt.Errorf("vless dial: %w", err)
	}
	return vlessConn, nil
}

func (d *VLESSDialer) doReality(ctx context.Context, rawConn net.Conn) (net.Conn, error) {
	// Use xray's utls fork for Reality (preserves Raw modifications through HandshakeContext)
	fp := xFingerprintID(d.fingerprint)

	tlsConn := xutls.UClient(rawConn, &xutls.Config{
		ServerName:         d.sni,
		InsecureSkipVerify: true,
	}, fp)

	if err := tlsConn.BuildHandshakeState(); err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("build: %w", err)
	}

	hello := tlsConn.HandshakeState.Hello

	// Step 1: Zero SessionID (xray-core: hello.SessionId = make + copy zeros to Raw)
	hello.SessionId = make([]byte, 32)
	copy(hello.Raw[39:], hello.SessionId) // zeros in Raw

	// Step 2: Fill plaintext SessionID
	hello.SessionId[0] = 26 // xray version
	hello.SessionId[1] = 2
	hello.SessionId[2] = 6
	hello.SessionId[3] = 0
	binary.BigEndian.PutUint32(hello.SessionId[4:], uint32(time.Now().Unix()))
	copy(hello.SessionId[8:], d.realityShortID)

	// Step 3: ECDH
	ecdheKey := tlsConn.HandshakeState.State13.KeyShareKeys.Ecdhe
	if ecdheKey == nil {
		ecdheKey = tlsConn.HandshakeState.State13.KeyShareKeys.MlkemEcdhe
	}
	if ecdheKey == nil {
		rawConn.Close()
		return nil, fmt.Errorf("no ECDHE key")
	}
	serverPub, err := ecdh.X25519().NewPublicKey(d.realityPubKey)
	if err != nil {
		rawConn.Close()
		return nil, err
	}
	authKey, err := ecdheKey.ECDH(serverPub)
	if err != nil {
		rawConn.Close()
		return nil, err
	}

	// Step 4: HKDF
	hkdfR := hkdf.New(sha256.New, authKey, hello.Random[:20], []byte("REALITY"))
	authKey = make([]byte, 32)
	if _, err := io.ReadFull(hkdfR, authKey); err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("hkdf: %w", err)
	}

	// Step 5: AEAD seal (AD = hello.Raw with zeros at SessionID)
	block, err := aes.NewCipher(authKey)
	if err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("aes cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("gcm: %w", err)
	}
	aead.Seal(hello.SessionId[:0], hello.Random[20:], hello.SessionId[:16], hello.Raw)
	// Now hello.SessionId has ciphertext
	copy(hello.Raw[39:], hello.SessionId) // update Raw with ciphertext

	log.Printf("[vless] Reality auth sealed, handshaking...")
	// xray's utls fork (v1.8.3-0.20260301) preserves Raw modifications through HandshakeContext
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("reality: %w", err)
	}
	log.Println("[vless] Reality OK!")
	return tlsConn, nil
}

func (d *VLESSDialer) doTLS(ctx context.Context, rawConn net.Conn) (net.Conn, error) {
	fp := fingerprintID(d.fingerprint)

	tlsConn := utls.UClient(rawConn, &utls.Config{
		ServerName:         d.sni,
		InsecureSkipVerify: true,
		// No ALPN — VLESS uses raw TCP stream, not HTTP/2
	}, fp)

	// Reality auth: use xtls/reality library (handles SessionID, ECDH, AEAD internally)
	if false && d.tlsMode == "reality" && len(d.realityPubKey) == 32 { // DISABLED — using reality.Client instead
		if err := tlsConn.BuildHandshakeState(); err != nil {
			rawConn.Close()
			return nil, fmt.Errorf("build handshake: %w", err)
		}

		hello := tlsConn.HandshakeState.Hello

		// Step 1: Build SessionID header
		// [0:3] = version (1, 8, 2 = fake xray version), [3] = 0
		// [4:8] = uint32 BE timestamp, [8:] = shortId
		hello.SessionId = make([]byte, 32)
		hello.SessionId[0] = 1  // version x
		hello.SessionId[1] = 8  // version y
		hello.SessionId[2] = 2  // version z
		hello.SessionId[3] = 0  // reserved
		binary.BigEndian.PutUint32(hello.SessionId[4:], uint32(time.Now().Unix()))
		copy(hello.SessionId[8:], d.realityShortID)

		// Step 2: Find our x25519 key from key_shares and compute ECDH
		var ecdheKey *ecdh.PrivateKey
		for _, ks := range hello.KeyShares {
			if ks.Group == utls.X25519 {
				// Extract the private key that uTLS generated
				// We need to replace with our own to control ECDH
				break
			}
		}

		// Generate our own x25519 keypair
		curve := ecdh.X25519()
		ecdheKey, err := curve.GenerateKey(rand.Reader)
		if err != nil {
			rawConn.Close()
			return nil, err
		}

		// Replace key_share with our public key
		for i, ks := range hello.KeyShares {
			if ks.Group == utls.X25519 {
				hello.KeyShares[i].Data = ecdheKey.PublicKey().Bytes()
				break
			}
		}

		// Step 3: Compute AuthKey
		serverPub, err := curve.NewPublicKey(d.realityPubKey)
		if err != nil {
			rawConn.Close()
			return nil, err
		}
		authKey, err := ecdheKey.ECDH(serverPub)
		if err != nil {
			rawConn.Close()
			return nil, err
		}

		// HKDF: AuthKey = HKDF-SHA256(sharedSecret, hello.Random[:20], "REALITY")
		hkdfReader := hkdf.New(sha256.New, authKey, hello.Random[:20], []byte("REALITY"))
		authKey = make([]byte, 32)
		if _, err := io.ReadFull(hkdfReader, authKey); err != nil {
			rawConn.Close()
			return nil, err
		}

		// Step 4: AEAD encrypt SessionID[:16] using AuthKey
		block, err := aes.NewCipher(authKey)
		if err != nil {
			rawConn.Close()
			return nil, err
		}
		aead, err := cipher.NewGCM(block)
		if err != nil {
			rawConn.Close()
			return nil, err
		}

		// Step 5: Marshal to get hello.Raw (needed as AEAD additional data)
		if err := tlsConn.MarshalClientHello(); err != nil {
			rawConn.Close()
			return nil, fmt.Errorf("first marshal: %w", err)
		}
		hello = tlsConn.HandshakeState.Hello // re-read after marshal

		// Step 6: AEAD seal SessionID using hello.Raw as AD
		// nonce = hello.Random[20:32] (12 bytes)
		// plaintext = SessionID[:16]
		// ad = hello.Raw (full ClientHello bytes)
		// output = SessionID[:32] (16 plaintext + 16 tag = 32)
		aead.Seal(hello.SessionId[:0], hello.Random[20:], hello.SessionId[:16], hello.Raw)

		// Step 7: Update Raw with encrypted SessionID and re-marshal
		copy(hello.Raw[39:], hello.SessionId)
		if err := tlsConn.MarshalClientHello(); err != nil {
			rawConn.Close()
			return nil, fmt.Errorf("second marshal: %w", err)
		}
	}

	if err := tlsConn.HandshakeContext(ctx); err != nil {
		rawConn.Close()
		return nil, err
	}

	return tlsConn, nil
}

func fingerprintID(name string) utls.ClientHelloID {
	switch strings.ToLower(name) {
	case "chrome":
		return utls.HelloChrome_Auto
	case "firefox":
		return utls.HelloFirefox_Auto
	case "safari":
		return utls.HelloSafari_Auto
	case "edge":
		return utls.HelloEdge_Auto
	case "random":
		return utls.HelloRandomized
	default:
		return utls.HelloChrome_Auto
	}
}

// nopLogger implements sing logger.ContextLogger as no-op
type nopLogger struct{}

func (nopLogger) Trace(args ...any)                          {}
func (nopLogger) Debug(args ...any)                          {}
func (nopLogger) Info(args ...any)                           {}
func (nopLogger) Warn(args ...any)                           {}
func (nopLogger) Error(args ...any)                          {}
func (nopLogger) Fatal(args ...any)                          {}
func (nopLogger) Panic(args ...any)                          {}
func (nopLogger) TraceContext(ctx context.Context, args ...any)  {}
func (nopLogger) DebugContext(ctx context.Context, args ...any)  {}
func (nopLogger) InfoContext(ctx context.Context, args ...any)   {}
func (nopLogger) WarnContext(ctx context.Context, args ...any)   {}
func (nopLogger) ErrorContext(ctx context.Context, args ...any)  {}
func (nopLogger) FatalContext(ctx context.Context, args ...any)  {}
func (nopLogger) PanicContext(ctx context.Context, args ...any)  {}

// buildVLESSHeader creates a raw VLESS request header
func buildVLESSHeader(uuid [16]byte, host string, port uint16) []byte {
	var buf []byte
	buf = append(buf, 0)        // version
	buf = append(buf, uuid[:]...) // UUID
	buf = append(buf, 0)        // no addon
	buf = append(buf, 1)        // TCP command

	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, port)
	buf = append(buf, portBytes...)

	ip := net.ParseIP(host)
	if ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			buf = append(buf, 1) // IPv4
			buf = append(buf, ip4...)
		} else {
			buf = append(buf, 3) // IPv6
			buf = append(buf, ip.To16()...)
		}
	} else {
		buf = append(buf, 2) // domain
		buf = append(buf, byte(len(host)))
		buf = append(buf, []byte(host)...)
	}
	return buf
}

// vlessRawConn wraps TLS conn, strips VLESS response header on first read
type vlessRawConn struct {
	net.Conn
	once    sync.Once
	hdrErr  error
}

func (c *vlessRawConn) Read(b []byte) (int, error) {
	c.once.Do(func() {
		hdr := make([]byte, 2)
		if _, err := io.ReadFull(c.Conn, hdr); err != nil {
			c.hdrErr = err
			return
		}
		addonLen := int(hdr[1])
		if addonLen > 0 {
			addon := make([]byte, addonLen)
			if _, err := io.ReadFull(c.Conn, addon); err != nil {
				c.hdrErr = err
				return
			}
		}
	})
	if c.hdrErr != nil {
		return 0, c.hdrErr
	}
	return c.Conn.Read(b)
}

func xFingerprintID(name string) xutls.ClientHelloID {
	switch strings.ToLower(name) {
	case "chrome":
		return xutls.HelloChrome_Auto
	case "firefox":
		return xutls.HelloFirefox_Auto
	case "safari":
		return xutls.HelloSafari_Auto
	case "edge":
		return xutls.HelloEdge_Auto
	case "random":
		return xutls.HelloRandomized
	default:
		return xutls.HelloChrome_Auto
	}
}

func init() {
	log.Println("[swinger] VLESS client loaded")
	_ = tls.Config{}
}
