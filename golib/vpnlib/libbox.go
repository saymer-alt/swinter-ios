package vpnlib

// Swinger — lightweight native protocol engine (replaces sing-box)
// Each protocol implemented as a standalone Go client.
// No heavy dependencies, fits in iOS NE memory limit.

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
)

var (
	sbMu     sync.Mutex
	sbCancel context.CancelFunc
	sbDialer ProxyDialer
	sbActive bool
)

// StartSingBox starts the native protocol engine (Swinger).
// Name kept for backward compat with iOS PacketTunnelProvider.
func StartSingBox(tunFd int32, configJSON string) error {
	sbMu.Lock()
	defer sbMu.Unlock()

	if sbActive {
		return fmt.Errorf("already running")
	}

	var sc ServerConfig
	if err := json.Unmarshal([]byte(configJSON), &sc); err != nil {
		return fmt.Errorf("parse config: %w", err)
	}

	log.Printf("[swinger] Starting: protocol=%s address=%s tunFd=%d", sc.Protocol, sc.Address, tunFd)

	ctx, cancel := context.WithCancel(context.Background())
	sbCancel = cancel

	// Create protocol dialer
	var dialer ProxyDialer
	var err error

	switch sc.Protocol {
	case "vless":
		dialer, err = NewVLESSDialer(sc)
	case "trojan":
		dialer, err = NewTrojanDialer(sc)
	case "shadowsocks":
		dialer, err = NewShadowsocksDialer(sc)
	case "vmess":
		dialer, err = NewVMessDialer(sc)
	case "hysteria2":
		dialer, err = NewHysteria2Dialer(sc)
	default:
		cancel()
		return fmt.Errorf("unsupported protocol: %s", sc.Protocol)
	}

	if err != nil {
		cancel()
		return fmt.Errorf("create %s dialer: %w", sc.Protocol, err)
	}
	sbDialer = dialer

	// Start DNS proxy (required — DNS queries hit TUN and get dropped without this)
	if err := StartDNSProxy(ctx); err != nil {
		log.Printf("[swinger] DNS proxy failed: %v (DNS may not work)", err)
	}

	// Start tun2socks
	if err := StartTun2Socks(ctx, int32(tunFd), dialer); err != nil {
		StopDNSProxy()
		dialer.Close()
		sbDialer = nil
		cancel()
		return fmt.Errorf("start proxy: %w", err)
	}

	sbActive = true
	log.Printf("[swinger] %s started OK", sc.Protocol)
	return nil
}

// StopSingBox stops the protocol engine.
func StopSingBox() {
	sbMu.Lock()
	defer sbMu.Unlock()

	if sbCancel != nil {
		sbCancel()
		sbCancel = nil
	}
	StopDNSProxy()
	if sbDialer != nil {
		sbDialer.Close()
		sbDialer = nil
	}
	sbActive = false
	log.Println("[swinger] Stopped")
}
