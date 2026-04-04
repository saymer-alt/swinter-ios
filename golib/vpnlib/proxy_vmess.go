package vpnlib

// Swinger — VMess client using sing-vmess library
// Supports: TCP, TLS, uTLS fingerprinting

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"time"

	utls "github.com/metacubex/utls"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing-vmess"
)

type VMessDialer struct {
	server      string
	client      *vmess.Client
	tlsMode     string
	sni         string
	fingerprint string
	transport   string
	wsPath      string
}

func NewVMessDialer(sc ServerConfig) (*VMessDialer, error) {
	if sc.VMess == nil {
		return nil, fmt.Errorf("VMess config missing")
	}
	v := sc.VMess

	security := v.Security
	if security == "" {
		security = "auto"
	}

	client, err := vmess.NewClient(v.UUID, security, v.AlterID)
	if err != nil {
		return nil, fmt.Errorf("create VMess client: %w", err)
	}

	sni := v.SNI
	if sni == "" {
		sni, _, _ = net.SplitHostPort(sc.Address)
	}

	transport := v.Transport
	if transport == "" {
		transport = "tcp"
	}

	return &VMessDialer{
		server:      sc.Address,
		client:      client,
		tlsMode:     v.TLS,
		sni:         sni,
		fingerprint: "chrome",
		transport:   transport,
		wsPath:      v.WSPath,
	}, nil
}

func (d *VMessDialer) Protocol() string { return "vmess" }
func (d *VMessDialer) Close() error     { return nil }

func (d *VMessDialer) DialTCP(ctx context.Context, destAddr string) (net.Conn, error) {
	log.Printf("[vmess] DialTCP %s via %s (tls=%s)", destAddr, d.server, d.tlsMode)

	dialer := &net.Dialer{Timeout: 10 * time.Second}

	rawConn, err := dialer.DialContext(ctx, "tcp", d.server)
	if err != nil {
		return nil, fmt.Errorf("tcp connect: %w", err)
	}

	// TLS handshake (optional for VMess)
	var conn net.Conn
	switch d.tlsMode {
	case "tls":
		if d.fingerprint != "" {
			tlsConn := utls.UClient(rawConn, &utls.Config{
				ServerName:         d.sni,
				InsecureSkipVerify: true,
			}, fingerprintID(d.fingerprint))
			if err := tlsConn.HandshakeContext(ctx); err != nil {
				rawConn.Close()
				return nil, fmt.Errorf("tls: %w", err)
			}
			conn = tlsConn
		} else {
			tlsConn := tls.Client(rawConn, &tls.Config{
				ServerName:         d.sni,
				InsecureSkipVerify: true,
			})
			if err := tlsConn.HandshakeContext(ctx); err != nil {
				rawConn.Close()
				return nil, fmt.Errorf("tls: %w", err)
			}
			conn = tlsConn
		}
	default:
		conn = rawConn
	}

	// WebSocket upgrade (if ws transport)
	if d.transport == "ws" {
		conn, err = wsUpgrade(conn, d.sni, d.wsPath)
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("ws upgrade: %w", err)
		}
	}

	// VMess protocol
	dest := M.ParseSocksaddr(destAddr)
	vmessConn, err := d.client.DialConn(conn, dest)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("vmess dial: %w", err)
	}

	return vmessConn, nil
}

func init() {
	log.Println("[swinger] VMess client loaded")
}
