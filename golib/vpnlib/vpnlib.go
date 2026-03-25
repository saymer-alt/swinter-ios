// Package vpnlib provides VPN functionality: TURN proxy + WireGuard.
// Built with gomobile for iOS Network Extension.
//
// Exports (gomobile-compatible):
//   - ResolveConfig(vkLink string) (string, error)  — get TURN IPs to exclude
//   - StartVPN(tunFd int32, configJSON string) error — start tunnel
//   - StopVPN()                                      — stop tunnel
package vpnlib

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

// config holds VPN configuration passed from iOS as JSON.
type config struct {
	VKLink       string `json:"vkLink"`
	PeerAddr     string `json:"peerAddr"`
	WGPrivateKey string `json:"wgPrivateKey"`
	WGPublicKey  string `json:"wgPublicKey"`
	WGAddress    string `json:"wgAddress"`
	WGDNS        string `json:"wgDNS"`
	TurnHost     string `json:"turnHost"`
	TurnUser     string `json:"turnUser"`
	TurnPass     string `json:"turnPass"`
	TurnAddr     string `json:"turnAddr"`
	UseUDP       bool   `json:"useUDP"`
	NumConns     int    `json:"numConns"`
	MTU          int    `json:"mtu"`
}

var (
	mu        sync.Mutex
	vpnCancel context.CancelFunc
	wgDevice  *device.Device
	running   bool
)

// ResolveConfig fetches TURN credentials and server info from VK link.
// Returns JSON with everything needed: turnIPs, apiIPs, turnUser, turnPass, turnAddr.
// Call from the MAIN APP (not NE) — NE will receive pre-fetched creds.
func ResolveConfig(vkLink string) (string, error) {
	link := extractVKLink(vkLink)
	if link == "" {
		return "", fmt.Errorf("invalid VK link")
	}

	// Fetch TURN credentials
	turnUser, turnPass, turnAddr, err := getVkCreds(link)
	if err != nil {
		return "", fmt.Errorf("failed to get TURN info: %w", err)
	}

	host, _, err := net.SplitHostPort(turnAddr)
	if err != nil {
		host = turnAddr
	}

	turnIPs, _ := net.LookupHost(host)

	apiHosts := []string{"login.vk.ru", "api.vk.ru", "calls.okcdn.ru"}
	var apiIPs []string
	for _, h := range apiHosts {
		ips, _ := net.LookupHost(h)
		apiIPs = append(apiIPs, ips...)
	}

	result := map[string]interface{}{
		"turnIPs":  turnIPs,
		"apiIPs":   apiIPs,
		"turnAddr": turnAddr,
		"turnUser": turnUser,
		"turnPass": turnPass,
	}

	b, err := json.Marshal(result)
	return string(b), err
}

// StartVPN starts the TURN proxy and WireGuard device.
//
// tunFd: utun file descriptor from iOS Network Extension
// configJSON: JSON string with VPN configuration
func StartVPN(tunFd int32, configJSON string) error {
	mu.Lock()
	defer mu.Unlock()

	if running {
		return fmt.Errorf("VPN already running")
	}

	var cfg config
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	if cfg.MTU <= 0 {
		cfg.MTU = 1280
	}
	if cfg.NumConns <= 0 {
		cfg.NumConns = 16
	}

	link := extractVKLink(cfg.VKLink)
	if link == "" {
		return fmt.Errorf("invalid VK link")
	}

	peer, err := net.ResolveUDPAddr("udp", cfg.PeerAddr)
	if err != nil {
		return fmt.Errorf("invalid peer address %q: %w", cfg.PeerAddr, err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	vpnCancel = cancel

	// Start TURN proxy on localhost:9000
	listenAddr := "127.0.0.1:9000"

	// Use pre-fetched credentials if available (from main app's ResolveConfig)
	// This avoids VK API calls from the NE which can fail with ip mismatch
	var getCreds getCredsFunc
	if cfg.TurnUser != "" && cfg.TurnPass != "" && cfg.TurnAddr != "" {
		// Use cached credentials
		cachedUser := cfg.TurnUser
		cachedPass := cfg.TurnPass
		cachedAddr := cfg.TurnAddr
		getCreds = func(link string) (string, string, string, error) {
			log.Printf("[vpnlib] Using pre-fetched TURN creds for %s", cachedAddr)
			return cachedUser, cachedPass, cachedAddr, nil
		}
	} else {
		getCreds = getVkCreds
	}

	params := &turnParams{
		host:     cfg.TurnHost,
		port:     "",
		link:     link,
		udp:      cfg.UseUDP,
		getCreds: getCreds,
	}

	readyCh := make(chan struct{}, 1)
	go startTurnProxy(ctx, params, peer, listenAddr, cfg.NumConns, readyCh)

	// Wait for TURN proxy to establish at least one connection
	log.Println("[vpnlib] Waiting for TURN connection...")
	select {
	case <-readyCh:
		log.Println("[vpnlib] TURN proxy ready")
	case <-time.After(30 * time.Second):
		cancel()
		return fmt.Errorf("TURN proxy connection timeout (30s)")
	case <-ctx.Done():
		return fmt.Errorf("cancelled")
	}

	// Start WireGuard
	log.Println("[vpnlib] Starting WireGuard...")
	err = startWireGuard(tunFd, cfg, listenAddr)
	if err != nil {
		cancel()
		return fmt.Errorf("WireGuard start failed: %w", err)
	}

	running = true
	log.Println("[vpnlib] VPN started successfully")
	return nil
}

// StopVPN stops the VPN tunnel.
func StopVPN() {
	mu.Lock()
	defer mu.Unlock()

	log.Println("[vpnlib] Stopping VPN...")

	if vpnCancel != nil {
		vpnCancel()
		vpnCancel = nil
	}

	if wgDevice != nil {
		wgDevice.Close()
		wgDevice = nil
	}

	running = false
	log.Println("[vpnlib] VPN stopped")
}

// startWireGuard creates a WireGuard device from the tun FD.
func startWireGuard(tunFd int32, cfg config, endpoint string) error {
	// Convert base64 keys to hex (WireGuard IPC uses hex)
	privKeyHex, err := b64ToHex(cfg.WGPrivateKey)
	if err != nil {
		return fmt.Errorf("bad private key: %w", err)
	}
	pubKeyHex, err := b64ToHex(cfg.WGPublicKey)
	if err != nil {
		return fmt.Errorf("bad public key: %w", err)
	}

	// Create TUN device from file descriptor
	// Use custom iOS TUN wrapper — standard CreateTUNFromFile fails
	// because it tries ioctl to set MTU, which NE sandbox blocks
	tunDev, err := createIOSTUN(int(tunFd), cfg.MTU)
	if err != nil {
		return fmt.Errorf("create TUN from fd %d: %w", tunFd, err)
	}

	// Create WireGuard device
	logger := device.NewLogger(device.LogLevelVerbose, "[wg] ")
	bind := conn.NewDefaultBind()
	dev := device.NewDevice(tunDev, bind, logger)

	// Configure via IPC
	ipcConfig := fmt.Sprintf(
		"private_key=%s\nlisten_port=0\nreplace_peers=true\npublic_key=%s\nendpoint=%s\nallowed_ip=0.0.0.0/0\nallowed_ip=::/0\npersistent_keepalive_interval=25\n",
		privKeyHex, pubKeyHex, endpoint,
	)

	if err := dev.IpcSet(ipcConfig); err != nil {
		dev.Close()
		return fmt.Errorf("IPC set: %w", err)
	}

	if err := dev.Up(); err != nil {
		dev.Close()
		return fmt.Errorf("device up: %w", err)
	}

	wgDevice = dev
	return nil
}

func extractVKLink(vkLink string) string {
	parts := strings.Split(vkLink, "join/")
	link := parts[len(parts)-1]
	if idx := strings.IndexAny(link, "/?#"); idx != -1 {
		link = link[:idx]
	}
	return strings.TrimSpace(link)
}

func b64ToHex(b64 string) (string, error) {
	// WireGuard keys are 32 bytes in base64
	b64 = strings.TrimSpace(b64)

	b, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		// Try URL-safe base64 (no padding)
		b, err = base64.RawURLEncoding.DecodeString(b64)
		if err != nil {
			// Try standard without padding
			b, err = base64.RawStdEncoding.DecodeString(b64)
			if err != nil {
				return "", fmt.Errorf("decode base64: %w", err)
			}
		}
	}

	if len(b) != 32 {
		return "", fmt.Errorf("key must be 32 bytes, got %d", len(b))
	}

	return hex.EncodeToString(b), nil
}
