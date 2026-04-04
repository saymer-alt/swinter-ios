package vpnlib

// Swinger — Hysteria2 client
// Protocol: QUIC with HTTP/3 auth, proxied TCP streams
// Wire: QUIC connection → HTTP/3 CONNECT → TCP stream

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
)

type Hysteria2Dialer struct {
	server   string
	password string
	sni      string
	conn     *quic.Conn
	mu       sync.Mutex
}

func NewHysteria2Dialer(sc ServerConfig) (*Hysteria2Dialer, error) {
	if sc.Hysteria2 == nil {
		return nil, fmt.Errorf("Hysteria2 config missing")
	}
	h := sc.Hysteria2

	sni := h.SNI
	if sni == "" {
		sni, _, _ = net.SplitHostPort(sc.Address)
	}

	return &Hysteria2Dialer{
		server:   sc.Address,
		password: h.Password,
		sni:      sni,
	}, nil
}

func (d *Hysteria2Dialer) Protocol() string { return "hysteria2" }

func (d *Hysteria2Dialer) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.conn != nil {
		d.conn.CloseWithError(0, "close")
		d.conn = nil
	}
	return nil
}

func (d *Hysteria2Dialer) getConn(ctx context.Context) (*quic.Conn, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if d.conn != nil {
		// Check if connection is still alive
		select {
		case <-d.conn.Context().Done():
			d.conn = nil
		default:
			return d.conn, nil
		}
	}

	// Establish QUIC connection
	tlsConfig := &tls.Config{
		ServerName:         d.sni,
		InsecureSkipVerify: true,
		NextProtos:         []string{"h3"},
	}

	quicConfig := &quic.Config{
		MaxIdleTimeout:  30 * time.Second,
		KeepAlivePeriod: 10 * time.Second,
	}

	conn, err := quic.DialAddr(ctx, d.server, tlsConfig, quicConfig)
	if err != nil {
		return nil, fmt.Errorf("quic dial: %w", err)
	}

	// Hysteria2 auth: open a control stream, send auth
	authStream, err := conn.OpenUniStreamSync(ctx)
	if err != nil {
		conn.CloseWithError(1, "auth stream failed")
		return nil, fmt.Errorf("open auth stream: %w", err)
	}

	// Hysteria2 auth frame: varint type (0x04 = auth) + varint len + password
	authPayload := []byte(d.password)
	authFrame := []byte{0x04} // auth type
	authFrame = appendVarint(authFrame, uint64(len(authPayload)))
	authFrame = append(authFrame, authPayload...)
	authStream.Write(authFrame)
	authStream.Close()

	d.conn = conn
	log.Printf("[hysteria2] QUIC connected to %s", d.server)
	return conn, nil
}

func (d *Hysteria2Dialer) DialTCP(ctx context.Context, destAddr string) (net.Conn, error) {
	log.Printf("[hysteria2] DialTCP %s via %s", destAddr, d.server)

	conn, err := d.getConn(ctx)
	if err != nil {
		return nil, err
	}

	// Open a new bidirectional stream for this TCP connection
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		// Connection might be dead, try reconnecting once
		d.mu.Lock()
		d.conn = nil
		d.mu.Unlock()
		conn, err = d.getConn(ctx)
		if err != nil {
			return nil, err
		}
		stream, err = conn.OpenStreamSync(ctx)
		if err != nil {
			return nil, fmt.Errorf("open stream: %w", err)
		}
	}

	// Hysteria2 TCP request: varint reqID + address
	host, portStr, _ := net.SplitHostPort(destAddr)
	port := 0
	fmt.Sscanf(portStr, "%d", &port)

	// Request frame: varint addr_len + addr + uint16 port + padding_len(0)
	var req []byte
	req = appendVarint(req, uint64(len(host))) // host length
	req = append(req, []byte(host)...)          // host
	portBuf := make([]byte, 2)
	binary.BigEndian.PutUint16(portBuf, uint16(port))
	req = append(req, portBuf...)  // port
	req = appendVarint(req, 0)     // padding length

	if _, err := stream.Write(req); err != nil {
		stream.Close()
		return nil, fmt.Errorf("write request: %w", err)
	}

	// Read response: status (1 byte) + message_len + message + padding_len + padding
	resp := make([]byte, 1)
	if _, err := io.ReadFull(stream, resp); err != nil {
		stream.Close()
		return nil, fmt.Errorf("read response: %w", err)
	}

	if resp[0] != 0x00 { // 0x00 = OK
		stream.Close()
		return nil, fmt.Errorf("hysteria2 server rejected: status %d", resp[0])
	}

	// Read and discard message + padding
	msgLen, err := readVarint(stream)
	if err != nil {
		stream.Close()
		return nil, err
	}
	if msgLen > 0 {
		io.CopyN(io.Discard, stream, int64(msgLen))
	}
	padLen, err := readVarint(stream)
	if err != nil {
		stream.Close()
		return nil, err
	}
	if padLen > 0 {
		io.CopyN(io.Discard, stream, int64(padLen))
	}

	return &hy2StreamConn{stream: stream, conn: conn}, nil
}

// hy2StreamConn wraps a QUIC stream as net.Conn
type hy2StreamConn struct {
	stream *quic.Stream
	conn   *quic.Conn
}

func (c *hy2StreamConn) Read(b []byte) (int, error)         { return c.stream.Read(b) }
func (c *hy2StreamConn) Write(b []byte) (int, error)        { return c.stream.Write(b) }
func (c *hy2StreamConn) Close() error                       { return c.stream.Close() }
func (c *hy2StreamConn) LocalAddr() net.Addr                { return c.conn.LocalAddr() }
func (c *hy2StreamConn) RemoteAddr() net.Addr               { return c.conn.RemoteAddr() }
func (c *hy2StreamConn) SetDeadline(t time.Time) error      { return c.stream.SetDeadline(t) }
func (c *hy2StreamConn) SetReadDeadline(t time.Time) error  { return c.stream.SetReadDeadline(t) }
func (c *hy2StreamConn) SetWriteDeadline(t time.Time) error { return c.stream.SetWriteDeadline(t) }

// appendVarint appends a QUIC-style variable-length integer
func appendVarint(b []byte, v uint64) []byte {
	if v < 0x40 {
		return append(b, byte(v))
	} else if v < 0x4000 {
		return append(b, byte(v>>8)|0x40, byte(v))
	} else if v < 0x40000000 {
		buf := make([]byte, 4)
		binary.BigEndian.PutUint32(buf, uint32(v)|0x80000000)
		return append(b, buf...)
	} else {
		buf := make([]byte, 8)
		binary.BigEndian.PutUint64(buf, v|0xC000000000000000)
		return append(b, buf...)
	}
}

// readVarint reads a QUIC-style variable-length integer
func readVarint(r io.Reader) (uint64, error) {
	first := make([]byte, 1)
	if _, err := io.ReadFull(r, first); err != nil {
		return 0, err
	}
	prefix := first[0] >> 6
	length := 1 << prefix
	if length == 1 {
		return uint64(first[0] & 0x3f), nil
	}
	rest := make([]byte, length-1)
	if _, err := io.ReadFull(r, rest); err != nil {
		return 0, err
	}
	buf := append([]byte{first[0] & 0x3f}, rest...)
	switch length {
	case 2:
		return uint64(binary.BigEndian.Uint16(buf)), nil
	case 4:
		return uint64(binary.BigEndian.Uint32(buf)), nil
	case 8:
		return binary.BigEndian.Uint64(buf), nil
	}
	return 0, fmt.Errorf("invalid varint length %d", length)
}

func init() {
	log.Println("[swinger] Hysteria2 client loaded")
}
