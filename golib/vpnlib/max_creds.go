package vpnlib

// MAX messenger TURN credential fetching via binary TCP protocol.
// Connects to api.oneme.ru:443 (standard TLS, NOT GOST),
// logs in with saved token, initiates call (opcode 78),
// extracts TURN credentials from response.

import (
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"time"

	"github.com/google/uuid"
	"github.com/vmihailenco/msgpack/v5"
)

const (
	maxTCPHost = "api.oneme.ru"
	maxTCPPort = "443"
	protoVer   = byte(10)
)

// getMaxCreds fetches TURN credentials via MAX binary TCP protocol.
// token: MAX auth token (from SMS login)
// targetUserID: user ID to "call" (gets brief ring, we only need TURN creds)
func getMaxCreds(token string, targetUserID int64) (string, string, string, error) {
	if token == "" {
		return "", "", "", fmt.Errorf("MAX token is empty")
	}
	if targetUserID == 0 {
		return "", "", "", fmt.Errorf("MAX target user ID is 0")
	}

	// Connect via TLS
	conn, err := tls.DialWithDialer(
		&net.Dialer{Timeout: 15 * time.Second},
		"tcp",
		net.JoinHostPort(maxTCPHost, maxTCPPort),
		&tls.Config{
			ServerName:         maxTCPHost,
			InsecureSkipVerify: true, // api.oneme.ru uses Russian CA
		},
	)
	if err != nil {
		return "", "", "", fmt.Errorf("MAX TCP connect: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))

	log.Println("[max] Connected to", maxTCPHost)

	var seq int16

	// Helper: send binary packet
	send := func(opcode int16, payload map[string]interface{}) error {
		data, err := msgpack.Marshal(payload)
		if err != nil {
			return fmt.Errorf("msgpack marshal: %w", err)
		}
		header := make([]byte, 10)
		header[0] = protoVer
		header[1] = 0 // cmd = request
		binary.BigEndian.PutUint16(header[2:4], uint16(seq))
		binary.BigEndian.PutUint16(header[4:6], uint16(opcode))
		binary.BigEndian.PutUint32(header[6:10], uint32(len(data)))
		seq++

		if _, err := conn.Write(header); err != nil {
			return err
		}
		if _, err := conn.Write(data); err != nil {
			return err
		}
		return nil
	}

	// Helper: receive binary packet
	recv := func() (int8, []byte, error) {
		header := make([]byte, 10)
		if _, err := io.ReadFull(conn, header); err != nil {
			return 0, nil, fmt.Errorf("read header: %w", err)
		}
		cmd := int8(header[1])
		lengthRaw := binary.BigEndian.Uint32(header[6:10])
		flags := (lengthRaw >> 24) & 0xFF
		payloadLen := int(lengthRaw & 0x00FFFFFF)

		payload := make([]byte, payloadLen)
		if payloadLen > 0 {
			if _, err := io.ReadFull(conn, payload); err != nil {
				return 0, nil, fmt.Errorf("read payload: %w", err)
			}
		}

		// If flags > 0, payload is LZ4 compressed — decompress
		if flags > 0 {
			decompressed, err := decompressLZ4Packet(payload, payloadLen)
			if err == nil {
				payload = decompressed
			}
			// If decompression fails, try raw (might work anyway)
		}

		return cmd, payload, nil
	}

	// 1. SESSION_INIT (opcode 6)
	err = send(6, map[string]interface{}{
		"userAgent": map[string]interface{}{
			"deviceType": "ANDROID",
			"locale":     "ru",
			"appVersion": "26.11.0",
		},
		"deviceId": uuid.New().String(),
	})
	if err != nil {
		return "", "", "", fmt.Errorf("MAX init send: %w", err)
	}
	cmd, _, err := recv()
	if err != nil {
		return "", "", "", fmt.Errorf("MAX init recv: %w", err)
	}
	if cmd != 1 {
		return "", "", "", fmt.Errorf("MAX init failed: cmd=%d", cmd)
	}
	log.Println("[max] Init OK")

	// 2. LOGIN (opcode 19)
	err = send(19, map[string]interface{}{
		"token":      token,
		"chatsCount": 0,
		"interactive": false,
	})
	if err != nil {
		return "", "", "", fmt.Errorf("MAX login send: %w", err)
	}
	cmd, _, err = recv()
	if err != nil {
		return "", "", "", fmt.Errorf("MAX login recv: %w", err)
	}
	if cmd != 1 {
		return "", "", "", fmt.Errorf("MAX login failed: cmd=%d (token expired?)", cmd)
	}
	log.Println("[max] Login OK")

	// 3. VIDEO_CHAT_START_ACTIVE (opcode 78) — initiate call → get TURN
	internalParams, _ := json.Marshal(map[string]interface{}{
		"platform":        "Android",
		"sdkVersion":      "0.1.7.1",
		"clientAppKey":    "CNHIJPLGDIHBABABA",
		"deviceId":        uuid.New().String(),
		"protocolVersion": 5,
		"capabilities":    "2A03F",
	})
	err = send(78, map[string]interface{}{
		"conversationId": uuid.New().String(),
		"calleeIds":      []int64{targetUserID},
		"isVideo":        false,
		"internalParams":  string(internalParams),
	})
	if err != nil {
		return "", "", "", fmt.Errorf("MAX call send: %w", err)
	}
	cmd, payload, err := recv()
	if err != nil {
		return "", "", "", fmt.Errorf("MAX call recv: %w", err)
	}
	if cmd != 1 {
		return "", "", "", fmt.Errorf("MAX call failed: cmd=%d, payload=%s", cmd, extractError(payload))
	}
	log.Println("[max] Call initiated, parsing TURN...")

	// 4. Extract internalCallerParams JSON from response
	icp, err := extractInternalCallerParams(payload)
	if err != nil {
		return "", "", "", fmt.Errorf("MAX parse params: %w", err)
	}

	var params struct {
		Turn struct {
			URLs       []string `json:"urls"`
			Username   string   `json:"username"`
			Credential string   `json:"credential"`
		} `json:"turn"`
	}
	if err := json.Unmarshal([]byte(icp), &params); err != nil {
		return "", "", "", fmt.Errorf("MAX parse TURN JSON: %w", err)
	}

	if len(params.Turn.URLs) == 0 {
		return "", "", "", fmt.Errorf("MAX: no TURN urls in response")
	}

	// Parse first TURN URL to get address
	addr := params.Turn.URLs[0]
	for _, prefix := range []string{"turn:", "turns:"} {
		if len(addr) > len(prefix) && addr[:len(prefix)] == prefix {
			addr = addr[len(prefix):]
		}
	}
	if idx := indexOfByte(addr, '?'); idx >= 0 {
		addr = addr[:idx]
	}

	ulen := len(params.Turn.Username)
	if ulen > 20 {
		ulen = 20
	}
	log.Printf("[max] Got TURN: %s (user=%s)", addr, params.Turn.Username[:ulen])
	return params.Turn.Username, params.Turn.Credential, addr, nil
}

func indexOfByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// extractInternalCallerParams finds the JSON string in binary response
func extractInternalCallerParams(data []byte) (string, error) {
	// Find "internalCallerParams" key in msgpack data
	marker := []byte("internalCallerParams")
	idx := -1
	for i := 0; i <= len(data)-len(marker); i++ {
		match := true
		for j := 0; j < len(marker); j++ {
			if data[i+j] != marker[j] {
				match = false
				break
			}
		}
		if match {
			idx = i + len(marker)
			break
		}
	}

	if idx < 0 || idx >= len(data) {
		return "", fmt.Errorf("internalCallerParams not found in response")
	}

	// Read msgpack string at this position
	b0 := data[idx]
	var strLen int
	var strStart int

	switch {
	case b0&0xE0 == 0xA0: // fixstr
		strLen = int(b0 & 0x1F)
		strStart = idx + 1
	case b0 == 0xD9: // str8
		if idx+1 >= len(data) {
			return "", fmt.Errorf("truncated str8")
		}
		strLen = int(data[idx+1])
		strStart = idx + 2
	case b0 == 0xDA: // str16
		if idx+2 >= len(data) {
			return "", fmt.Errorf("truncated str16")
		}
		strLen = int(data[idx+1])<<8 | int(data[idx+2])
		strStart = idx + 3
	case b0 == 0xDB: // str32
		if idx+4 >= len(data) {
			return "", fmt.Errorf("truncated str32")
		}
		strLen = int(data[idx+1])<<24 | int(data[idx+2])<<16 | int(data[idx+3])<<8 | int(data[idx+4])
		strStart = idx + 5
	default:
		return "", fmt.Errorf("unexpected msgpack type 0x%02x after key", b0)
	}

	if strStart+strLen > len(data) {
		return "", fmt.Errorf("string truncated: need %d, have %d", strLen, len(data)-strStart)
	}

	return string(data[strStart : strStart+strLen]), nil
}

// decompressLZ4Packet decompresses LZ4 block format used by TamTam
func decompressLZ4Packet(compressed []byte, compressedLen int) ([]byte, error) {
	// Try increasing output buffer sizes
	for mult := 2; mult <= 20; mult++ {
		outSize := compressedLen * mult
		out := make([]byte, outSize)
		n := lz4BlockDecode(compressed, out)
		if n > 0 {
			return out[:n], nil
		}
	}
	return nil, fmt.Errorf("LZ4 decompression failed")
}

// lz4BlockDecode is a minimal LZ4 block decoder
func lz4BlockDecode(src, dst []byte) int {
	sIdx, dIdx := 0, 0
	for sIdx < len(src) {
		token := src[sIdx]
		sIdx++

		// Literal length
		litLen := int(token >> 4)
		if litLen == 15 {
			for sIdx < len(src) {
				b := src[sIdx]
				sIdx++
				litLen += int(b)
				if b != 255 {
					break
				}
			}
		}

		// Copy literals
		if sIdx+litLen > len(src) || dIdx+litLen > len(dst) {
			if sIdx+litLen <= len(src) && dIdx+litLen <= len(dst) {
				copy(dst[dIdx:], src[sIdx:sIdx+litLen])
				dIdx += litLen
			}
			return dIdx
		}
		copy(dst[dIdx:], src[sIdx:sIdx+litLen])
		dIdx += litLen
		sIdx += litLen

		if sIdx >= len(src) {
			return dIdx
		}

		// Match offset
		if sIdx+2 > len(src) {
			return dIdx
		}
		offset := int(src[sIdx]) | int(src[sIdx+1])<<8
		sIdx += 2
		if offset == 0 {
			return dIdx
		}

		// Match length
		matchLen := int(token&0x0F) + 4
		if matchLen == 19 { // 15 + 4
			for sIdx < len(src) {
				b := src[sIdx]
				sIdx++
				matchLen += int(b)
				if b != 255 {
					break
				}
			}
		}

		// Copy match
		matchStart := dIdx - offset
		if matchStart < 0 || dIdx+matchLen > len(dst) {
			return dIdx
		}
		for i := 0; i < matchLen; i++ {
			dst[dIdx] = dst[matchStart+i]
			dIdx++
		}
	}
	return dIdx
}

// extractError tries to get error message from failed response
func extractError(data []byte) string {
	// Find "message" key
	marker := []byte("message")
	for i := 0; i <= len(data)-len(marker); i++ {
		match := true
		for j := 0; j < len(marker); j++ {
			if data[i+j] != marker[j] {
				match = false
				break
			}
		}
		if match {
			idx := i + len(marker)
			if idx < len(data) {
				b0 := data[idx]
				var strLen, strStart int
				switch {
				case b0&0xE0 == 0xA0:
					strLen = int(b0 & 0x1F)
					strStart = idx + 1
				case b0 == 0xD9 && idx+1 < len(data):
					strLen = int(data[idx+1])
					strStart = idx + 2
				case b0 == 0xDA && idx+2 < len(data):
					strLen = int(data[idx+1])<<8 | int(data[idx+2])
					strStart = idx + 3
				}
				if strLen > 0 && strStart+strLen <= len(data) {
					return string(data[strStart : strStart+strLen])
				}
			}
			break
		}
	}
	return fmt.Sprintf("(raw %d bytes)", len(data))
}
