package vpnlib

// Swinger — Trojan protocol client
// Wire: SHA224(password) hex + CRLF + cmd + address + CRLF + payload

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"log"
	"net"
	"time"

	utls "github.com/metacubex/utls"
)

type TrojanDialer struct {
	server      string
	passHash    string // hex SHA224
	sni         string
	fingerprint string
	transport   string
	wsPath      string
}

func NewTrojanDialer(sc ServerConfig) (*TrojanDialer, error) {
	if sc.Trojan == nil {
		return nil, fmt.Errorf("Trojan config missing")
	}
	t := sc.Trojan

	// SHA224 of password
	h := sha256.New224()
	h.Write([]byte(t.Password))
	passHash := hex.EncodeToString(h.Sum(nil))

	sni := t.SNI
	if sni == "" {
		sni, _, _ = net.SplitHostPort(sc.Address)
	}

	transport := t.Transport
	if transport == "" {
		transport = "tcp"
	}

	return &TrojanDialer{
		server:      sc.Address,
		passHash:    passHash,
		sni:         sni,
		fingerprint: "chrome",
		transport:   transport,
		wsPath:      t.WSPath,
	}, nil
}

func (d *TrojanDialer) Protocol() string { return "trojan" }
func (d *TrojanDialer) Close() error     { return nil }

func (d *TrojanDialer) DialTCP(ctx context.Context, destAddr string) (net.Conn, error) {
	rawConn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", d.server)
	if err != nil {
		return nil, err
	}

	// TLS (mandatory for Trojan)
	var conn net.Conn
	if d.fingerprint != "" {
		tlsConn := utls.UClient(rawConn, &utls.Config{
			ServerName:         d.sni,
			InsecureSkipVerify: true,
		}, fingerprintID(d.fingerprint))
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			rawConn.Close()
			return nil, err
		}
		conn = tlsConn
	} else {
		tlsConn := tls.Client(rawConn, &tls.Config{
			ServerName:         d.sni,
			InsecureSkipVerify: true,
		})
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			rawConn.Close()
			return nil, err
		}
		conn = tlsConn
	}

	// WebSocket upgrade (if ws transport)
	if d.transport == "ws" {
		conn, err = wsUpgrade(conn, d.sni, d.wsPath)
		if err != nil {
			conn.Close()
			return nil, err
		}
	}

	// Send Trojan header
	host, portStr, _ := net.SplitHostPort(destAddr)
	port := 0
	fmt.Sscanf(portStr, "%d", &port)

	var header []byte
	header = append(header, []byte(d.passHash)...)
	header = append(header, '\r', '\n')
	header = append(header, 1) // TCP command

	// Address
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, uint16(port))

	ip := net.ParseIP(host)
	if ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			header = append(header, 1) // IPv4
			header = append(header, ip4...)
		} else {
			header = append(header, 4) // IPv6
			header = append(header, ip...)
		}
	} else {
		header = append(header, 3) // domain
		header = append(header, byte(len(host)))
		header = append(header, []byte(host)...)
	}
	header = append(header, portBytes...)
	header = append(header, '\r', '\n')

	if _, err := conn.Write(header); err != nil {
		conn.Close()
		return nil, err
	}

	return conn, nil
}

func init() {
	log.Println("[swinger] Trojan client loaded")
}
