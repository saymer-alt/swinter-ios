package vpnlib

// Swinger — Shadowsocks AEAD client
// Wire: [salt][encrypted chunks: [2b enc len][len tag][enc data][data tag]]
// Key derivation: HKDF-SHA1

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

const ssMaxPayload = 16384

type ShadowsocksDialer struct {
	server   string
	method   string
	password string
	keyLen   int
}

func NewShadowsocksDialer(sc ServerConfig) (*ShadowsocksDialer, error) {
	if sc.Shadowsocks == nil {
		return nil, fmt.Errorf("Shadowsocks config missing")
	}
	ss := sc.Shadowsocks

	keyLen := 32
	switch ss.Method {
	case "aes-128-gcm":
		keyLen = 16
	case "aes-256-gcm", "chacha20-ietf-poly1305":
		keyLen = 32
	default:
		return nil, fmt.Errorf("unsupported method: %s", ss.Method)
	}

	return &ShadowsocksDialer{
		server:   sc.Address,
		method:   ss.Method,
		password: ss.Password,
		keyLen:   keyLen,
	}, nil
}

func (d *ShadowsocksDialer) Protocol() string { return "shadowsocks" }
func (d *ShadowsocksDialer) Close() error     { return nil }

func (d *ShadowsocksDialer) DialTCP(ctx context.Context, destAddr string) (net.Conn, error) {
	conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", d.server)
	if err != nil {
		return nil, err
	}

	// Derive key from password
	key := kdf(d.password, d.keyLen)

	// Generate salt
	salt := make([]byte, d.keyLen)
	if _, err := rand.Read(salt); err != nil {
		conn.Close()
		return nil, err
	}

	// Derive session key
	sessionKey := make([]byte, d.keyLen)
	hkdfReader := hkdf.New(sha1.New, key, salt, []byte("ss-subkey"))
	if _, err := io.ReadFull(hkdfReader, sessionKey); err != nil {
		conn.Close()
		return nil, err
	}

	// Create AEAD cipher
	aead, err := d.createAEAD(sessionKey)
	if err != nil {
		conn.Close()
		return nil, err
	}

	// Write salt
	if _, err := conn.Write(salt); err != nil {
		conn.Close()
		return nil, err
	}

	// Build address header
	host, portStr, _ := net.SplitHostPort(destAddr)
	port := 0
	fmt.Sscanf(portStr, "%d", &port)

	var addrHeader []byte
	ip := net.ParseIP(host)
	if ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			addrHeader = append(addrHeader, 1)
			addrHeader = append(addrHeader, ip4...)
		} else {
			addrHeader = append(addrHeader, 4)
			addrHeader = append(addrHeader, ip...)
		}
	} else {
		addrHeader = append(addrHeader, 3)
		addrHeader = append(addrHeader, byte(len(host)))
		addrHeader = append(addrHeader, []byte(host)...)
	}
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, uint16(port))
	addrHeader = append(addrHeader, portBytes...)

	// Encrypt and write address header as first payload
	ssConn := &ssAEADConn{
		Conn:     conn,
		wAEAD:    aead,
		wNonce:   make([]byte, aead.NonceSize()),
		rKey:     key,
		rKeyLen:  d.keyLen,
		method:   d.method,
		createAEAD: d.createAEAD,
	}

	if _, err := ssConn.Write(addrHeader); err != nil {
		conn.Close()
		return nil, err
	}

	return ssConn, nil
}

func (d *ShadowsocksDialer) createAEAD(key []byte) (cipher.AEAD, error) {
	switch d.method {
	case "aes-128-gcm", "aes-256-gcm":
		block, err := aes.NewCipher(key)
		if err != nil {
			return nil, err
		}
		return cipher.NewGCM(block)
	case "chacha20-ietf-poly1305":
		return chacha20poly1305.New(key)
	default:
		return nil, fmt.Errorf("unsupported: %s", d.method)
	}
}

// ssAEADConn wraps connection with SS AEAD encryption
type ssAEADConn struct {
	net.Conn
	wAEAD      cipher.AEAD
	wNonce     []byte
	rAEAD      cipher.AEAD
	rNonce     []byte
	rBuf       []byte
	rKey       []byte
	rKeyLen    int
	rInit      bool
	method     string
	createAEAD func([]byte) (cipher.AEAD, error)
}

func (c *ssAEADConn) Write(b []byte) (int, error) {
	// Chunk payload per SS spec (max 0x3FFF = 16383 bytes per chunk)
	const maxChunk = 0x3FFF
	total := 0
	for len(b) > 0 {
		chunk := b
		if len(chunk) > maxChunk {
			chunk = b[:maxChunk]
		}
		b = b[len(chunk):]

		// Encrypt: [enc_len 2b][len_tag][enc_data][data_tag]
		lenBuf := make([]byte, 2)
		binary.BigEndian.PutUint16(lenBuf, uint16(len(chunk)))
		encLen := c.wAEAD.Seal(nil, c.wNonce, lenBuf, nil)
		increment(c.wNonce)

		encData := c.wAEAD.Seal(nil, c.wNonce, chunk, nil)
		increment(c.wNonce)

		buf := make([]byte, 0, len(encLen)+len(encData))
		buf = append(buf, encLen...)
		buf = append(buf, encData...)

		if _, err := c.Conn.Write(buf); err != nil {
			return total, err
		}
		total += len(chunk)
	}
	return total, nil
}

func (c *ssAEADConn) Read(b []byte) (int, error) {
	// Return buffered data first
	if len(c.rBuf) > 0 {
		n := copy(b, c.rBuf)
		c.rBuf = c.rBuf[n:]
		return n, nil
	}

	// Initialize read AEAD on first read
	if !c.rInit {
		salt := make([]byte, c.rKeyLen)
		if _, err := io.ReadFull(c.Conn, salt); err != nil {
			return 0, err
		}
		sessionKey := make([]byte, c.rKeyLen)
		hkdfReader := hkdf.New(sha1.New, c.rKey, salt, []byte("ss-subkey"))
		if _, err := io.ReadFull(hkdfReader, sessionKey); err != nil {
			return 0, err
		}
		aead, err := c.createAEAD(sessionKey)
		if err != nil {
			return 0, err
		}
		c.rAEAD = aead
		c.rNonce = make([]byte, aead.NonceSize())
		c.rInit = true
	}

	// Read encrypted length
	encLenBuf := make([]byte, 2+c.rAEAD.Overhead())
	if _, err := io.ReadFull(c.Conn, encLenBuf); err != nil {
		return 0, err
	}
	lenBuf, err := c.rAEAD.Open(nil, c.rNonce, encLenBuf, nil)
	if err != nil {
		return 0, err
	}
	increment(c.rNonce)

	dataLen := int(binary.BigEndian.Uint16(lenBuf))

	// Read encrypted data
	encDataBuf := make([]byte, dataLen+c.rAEAD.Overhead())
	if _, err := io.ReadFull(c.Conn, encDataBuf); err != nil {
		return 0, err
	}
	data, err := c.rAEAD.Open(nil, c.rNonce, encDataBuf, nil)
	if err != nil {
		return 0, err
	}
	increment(c.rNonce)

	n := copy(b, data)
	if n < len(data) {
		c.rBuf = data[n:]
	}
	return n, nil
}

// increment nonce (little-endian counter)
func increment(nonce []byte) {
	for i := range nonce {
		nonce[i]++
		if nonce[i] != 0 {
			break
		}
	}
}

// kdf derives key from password using EVP_BytesToKey
func kdf(password string, keyLen int) []byte {
	var b, prev []byte
	h := md5.New()
	for len(b) < keyLen {
		h.Reset()
		h.Write(prev)
		h.Write([]byte(password))
		prev = h.Sum(nil)
		b = append(b, prev...)
	}
	return b[:keyLen]
}

func init() {
	log.Println("[swinger] Shadowsocks client loaded")
}
