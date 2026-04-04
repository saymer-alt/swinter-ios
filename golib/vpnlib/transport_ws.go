package vpnlib

// WebSocket transport for VLESS/VMess/Trojan
// Implements RFC 6455 handshake over TLS, then wraps as net.Conn
// No external dependency — uses raw HTTP upgrade + frame read/write

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

const (
	wsMagicGUID    = "258EAFA5-E914-47DA-95CA-5CF5DC85B76A"
	wsMaxFrameSize = 16 * 1024 * 1024 // 16 MB max frame
)

// wsUpgrade performs WebSocket handshake on an existing connection.
// The connection should already have TLS established if needed.
func wsUpgrade(conn net.Conn, host, path string) (net.Conn, error) {
	if path == "" {
		path = "/"
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}

	// Generate random key
	keyBytes := make([]byte, 16)
	rand.Read(keyBytes)
	wsKey := base64.StdEncoding.EncodeToString(keyBytes)

	// Send upgrade request
	req := fmt.Sprintf("GET %s HTTP/1.1\r\n"+
		"Host: %s\r\n"+
		"Upgrade: websocket\r\n"+
		"Connection: Upgrade\r\n"+
		"Sec-WebSocket-Key: %s\r\n"+
		"Sec-WebSocket-Version: 13\r\n"+
		"\r\n", path, host, wsKey)

	if _, err := conn.Write([]byte(req)); err != nil {
		return nil, fmt.Errorf("ws upgrade write: %w", err)
	}

	// Read response
	reader := bufio.NewReader(conn)
	resp, err := http.ReadResponse(reader, nil)
	if err != nil {
		return nil, fmt.Errorf("ws upgrade read: %w", err)
	}
	resp.Body.Close()

	if resp.StatusCode != 101 {
		return nil, fmt.Errorf("ws upgrade: status %d", resp.StatusCode)
	}

	// Verify accept key
	h := sha1.New()
	h.Write([]byte(wsKey + wsMagicGUID))
	expectedAccept := base64.StdEncoding.EncodeToString(h.Sum(nil))
	if resp.Header.Get("Sec-WebSocket-Accept") != expectedAccept {
		return nil, fmt.Errorf("ws upgrade: bad accept key")
	}

	// Wrap as framed connection
	return &wsConn{
		Conn:    conn,
		reader:  reader,
		rawConn: conn,
	}, nil
}

// wsConn wraps a WebSocket connection as net.Conn
// Handles binary frame read/write with masking
type wsConn struct {
	net.Conn
	reader  *bufio.Reader
	rawConn net.Conn
	readBuf []byte // buffered payload from current frame
}

func (c *wsConn) Close() error {
	// Send close frame (best effort)
	closeFrame := wsEncodeFrame(0x08, []byte{0x03, 0xE8}) // 1000 = normal closure
	c.rawConn.SetWriteDeadline(time.Now().Add(1 * time.Second))
	c.rawConn.Write(closeFrame)
	return c.rawConn.Close()
}

func (c *wsConn) Write(b []byte) (int, error) {
	// Write binary frame with masking (client MUST mask)
	frame := wsEncodeFrame(0x02, b) // 0x02 = binary
	_, err := c.Conn.Write(frame)
	if err != nil {
		return 0, err
	}
	return len(b), nil
}

func (c *wsConn) Read(b []byte) (int, error) {
	// Return buffered data first
	if len(c.readBuf) > 0 {
		n := copy(b, c.readBuf)
		c.readBuf = c.readBuf[n:]
		return n, nil
	}

	// Read next frame
	payload, err := c.readFrame()
	if err != nil {
		return 0, err
	}

	n := copy(b, payload)
	if n < len(payload) {
		c.readBuf = payload[n:]
	}
	return n, nil
}

func (c *wsConn) readFrame() ([]byte, error) {
	for {
		// Read frame header (2 bytes min)
		hdr := make([]byte, 2)
		if _, err := io.ReadFull(c.reader, hdr); err != nil {
			return nil, err
		}

		opcode := hdr[0] & 0x0f
		masked := (hdr[1] & 0x80) != 0
		payloadLen := int(hdr[1] & 0x7f)

		// Extended length
		if payloadLen == 126 {
			ext := make([]byte, 2)
			if _, err := io.ReadFull(c.reader, ext); err != nil {
				return nil, err
			}
			payloadLen = int(binary.BigEndian.Uint16(ext))
		} else if payloadLen == 127 {
			ext := make([]byte, 8)
			if _, err := io.ReadFull(c.reader, ext); err != nil {
				return nil, err
			}
			payloadLen = int(binary.BigEndian.Uint64(ext))
		}

		if payloadLen > wsMaxFrameSize {
			return nil, fmt.Errorf("ws frame too large: %d bytes", payloadLen)
		}

		// Mask key (server frames usually not masked, but handle it)
		var maskKey [4]byte
		if masked {
			if _, err := io.ReadFull(c.reader, maskKey[:]); err != nil {
				return nil, err
			}
		}

		// Payload
		payload := make([]byte, payloadLen)
		if _, err := io.ReadFull(c.reader, payload); err != nil {
			return nil, err
		}

		if masked {
			for i := range payload {
				payload[i] ^= maskKey[i%4]
			}
		}

		switch opcode {
		case 0x01, 0x02: // text or binary
			return payload, nil
		case 0x08: // close
			return nil, io.EOF
		case 0x09: // ping — respond with pong
			pong := wsEncodeFrame(0x0a, payload)
			c.Conn.Write(pong)
			continue
		case 0x0a: // pong — ignore
			continue
		default:
			continue
		}
	}
}

func wsEncodeFrame(opcode byte, payload []byte) []byte {
	var frame []byte

	// FIN + opcode
	frame = append(frame, 0x80|opcode)

	// Length + mask bit (client MUST mask)
	plen := len(payload)
	if plen < 126 {
		frame = append(frame, byte(plen)|0x80) // masked
	} else if plen <= 65535 {
		frame = append(frame, 126|0x80)
		lenBytes := make([]byte, 2)
		binary.BigEndian.PutUint16(lenBytes, uint16(plen))
		frame = append(frame, lenBytes...)
	} else {
		frame = append(frame, 127|0x80)
		lenBytes := make([]byte, 8)
		binary.BigEndian.PutUint64(lenBytes, uint64(plen))
		frame = append(frame, lenBytes...)
	}

	// Mask key
	maskKey := make([]byte, 4)
	rand.Read(maskKey)
	frame = append(frame, maskKey...)

	// Masked payload
	masked := make([]byte, plen)
	for i, b := range payload {
		masked[i] = b ^ maskKey[i%4]
	}
	frame = append(frame, masked...)

	return frame
}
