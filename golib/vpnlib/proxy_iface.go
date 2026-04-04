package vpnlib

// Swinger — ProxyDialer interface
// All protocol clients implement this interface.

import (
	"context"
	"encoding/hex"
	"fmt"
	"net"
	"strings"
)

// ProxyDialer creates connections through a proxy protocol (VLESS, Trojan, etc.)
type ProxyDialer interface {
	// DialTCP connects to addr (host:port) through the proxy
	DialTCP(ctx context.Context, addr string) (net.Conn, error)

	// Close shuts down the dialer
	Close() error

	// Protocol returns the protocol name
	Protocol() string
}

// parseUUID parses a UUID string (with or without dashes) into [16]byte
func parseUUID(s string) ([16]byte, error) {
	var uuid [16]byte
	s = strings.ReplaceAll(s, "-", "")
	if len(s) != 32 {
		return uuid, fmt.Errorf("invalid UUID length: %d", len(s))
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return uuid, err
	}
	copy(uuid[:], b)
	return uuid, nil
}
