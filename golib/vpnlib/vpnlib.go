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
	"reflect"
	"strings"
	"sync"
	"time"
	"unsafe"

	awgDevice "github.com/amnezia-vpn/amneziawg-go/device"
	awgConn "github.com/amnezia-vpn/amneziawg-go/conn"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

// config holds VPN configuration passed from iOS as JSON.
type config struct {
	Protocol     string `json:"protocol"` // "" or "wireguard" or "amneziawg"
	VKLink       string `json:"vkLink"`
	PeerAddr     string `json:"peerAddr"`
	WGPrivateKey  string `json:"wgPrivateKey"`
	WGPublicKey   string `json:"wgPublicKey"`
	PresharedKey  string `json:"presharedKey"`
	WGAddress    string `json:"wgAddress"`
	WGDNS        string `json:"wgDNS"`
	TurnHost     string `json:"turnHost"`
	TurnUser     string `json:"turnUser"`
	TurnPass     string `json:"turnPass"`
	TurnAddr     string `json:"turnAddr"`
	UseUDP       bool   `json:"useUDP"`
	NumConns     int    `json:"numConns"`
	MTU          int    `json:"mtu"`
	// AmneziaWG parameters
	Jc   int `json:"Jc"`
	Jmin int `json:"Jmin"`
	Jmax int `json:"Jmax"`
	S1   int `json:"S1"`
	S2   int `json:"S2"`
	H1   int `json:"H1"`
	H2   int `json:"H2"`
	H3   int `json:"H3"`
	H4   int `json:"H4"`
}

var (
	mu        sync.Mutex
	vpnCancel context.CancelFunc
	wgDevice  *device.Device
	awgDev    *awgDevice.Device
	running   bool
	dnsCache  = make(map[string]*net.UDPAddr)

	// WireGuard bind socket FDs for VpnService.protect() on Android
	wgSocketV4 int32 = -1
	wgSocketV6 int32 = -1

	// Pending WG devices (waiting for socket protection before Up)
	pendingWGDev  *device.Device
	pendingAWGDev *awgDevice.Device
)

// ResolveConfigMAX fetches TURN credentials via MAX messenger call.
// token: MAX auth token, targetUserID: user to "call" for TURN creds.
func ResolveConfigMAX(token string, targetUserID int64) (string, error) {
	turnUser, turnPass, turnAddr, err := getMaxCreds(token, targetUserID)
	if err != nil {
		return "", fmt.Errorf("MAX TURN: %w", err)
	}

	host := turnAddr
	if h, _, err := net.SplitHostPort(turnAddr); err == nil {
		host = h
	}
	turnIPs, _ := net.LookupHost(host)

	result := map[string]interface{}{
		"turnIPs":  turnIPs,
		"apiIPs":   []string{},
		"turnAddr": turnAddr,
		"turnUser": turnUser,
		"turnPass": turnPass,
	}
	b, err := json.Marshal(result)
	return string(b), err
}

// ResolveConfig fetches TURN credentials and server info from VK link.
// Returns JSON with everything needed: turnIPs, apiIPs, turnUser, turnPass, turnAddr.
// Call from the MAIN APP (not NE) — NE will receive pre-fetched creds.
func ResolveConfig(vkLink string) (string, error) {
	link := extractVKLink(vkLink)
	if link == "" {
		return "", fmt.Errorf("invalid VK link")
	}

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

	peer, err := net.ResolveUDPAddr("udp", cfg.PeerAddr)
	if err != nil {
		// Fallback: try cached IP for this hostname
		if cached, ok := dnsCache[cfg.PeerAddr]; ok {
			log.Printf("[vpnlib] DNS resolve failed, using cached: %s → %s", cfg.PeerAddr, cached.String())
			peer = cached
		} else {
			return fmt.Errorf("invalid peer address %q: %w", cfg.PeerAddr, err)
		}
	} else {
		// Cache successful resolution
		dnsCache[cfg.PeerAddr] = peer
		log.Printf("[vpnlib] Resolved %s → %s", cfg.PeerAddr, peer.String())
	}

	ctx, cancel := context.WithCancel(context.Background())
	vpnCancel = cancel

	// Determine mode: TURN proxy or direct WireGuard
	hasTURN := cfg.TurnUser != "" && cfg.TurnPass != "" && cfg.TurnAddr != ""
	hasVKLink := extractVKLink(cfg.VKLink) != ""

	var wgEndpoint string

	if hasTURN || hasVKLink {
		// TURN mode: start proxy on localhost:9000, WG connects to proxy
		listenAddr := "127.0.0.1:9000"
		wgEndpoint = listenAddr

		var getCreds getCredsFunc
		var link string
		if hasTURN {
			cachedUser := cfg.TurnUser
			cachedPass := cfg.TurnPass
			cachedAddr := cfg.TurnAddr
			getCreds = func(link string) (string, string, string, error) {
				log.Printf("[vpnlib] Using pre-fetched TURN creds for %s", cachedAddr)
				return cachedUser, cachedPass, cachedAddr, nil
			}
			link = "prefetched"
		} else {
			link = extractVKLink(cfg.VKLink)
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
	} else {
		// Direct mode: WG connects to peer directly (no TURN)
		// Use resolved IP (WG IPC doesn't accept hostnames)
		wgEndpoint = peer.String()
		log.Printf("[vpnlib] Direct mode: WG endpoint = %s (resolved from %s)", wgEndpoint, cfg.PeerAddr)
	}

	// Start WireGuard
	log.Println("[vpnlib] Starting WireGuard...")
	err = startWireGuard(tunFd, cfg, wgEndpoint)
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
	if awgDev != nil {
		awgDev.Close()
		awgDev = nil
	}

	running = false
	log.Println("[vpnlib] VPN stopped")
}

// startWireGuard creates a WireGuard or AmneziaWG device from the tun FD.
func startWireGuard(tunFd int32, cfg config, endpoint string) error {
	privKeyHex, err := b64ToHex(cfg.WGPrivateKey)
	if err != nil {
		return fmt.Errorf("bad private key: %w", err)
	}
	pubKeyHex, err := b64ToHex(cfg.WGPublicKey)
	if err != nil {
		return fmt.Errorf("bad public key: %w", err)
	}

	var pskLine string
	if cfg.PresharedKey != "" {
		pskHex, err := b64ToHex(cfg.PresharedKey)
		if err != nil {
			return fmt.Errorf("bad preshared key: %w", err)
		}
		pskLine = fmt.Sprintf("preshared_key=%s\n", pskHex)
	}

	isAWG := cfg.Protocol == "amneziawg" && (cfg.Jc > 0 || cfg.S1 > 0 || cfg.H1 > 1)

	if isAWG {
		log.Printf("[vpnlib] Starting AmneziaWG (Jc=%d S1=%d H1=%d)", cfg.Jc, cfg.S1, cfg.H1)

		awgTunDev, err := createAWGTUN(int(tunFd), cfg.MTU)
		if err != nil {
			return fmt.Errorf("create AWG TUN: %w", err)
		}

		logger := awgDevice.NewLogger(awgDevice.LogLevelVerbose, "[awg] ")
		bind := awgConn.NewDefaultBind()

		dev := awgDevice.NewDevice(awgTunDev, bind, logger)

		ipcConfig := fmt.Sprintf(
			"private_key=%s\nlisten_port=0\njc=%d\njmin=%d\njmax=%d\ns1=%d\ns2=%d\nh1=%d\nh2=%d\nh3=%d\nh4=%d\nreplace_peers=true\npublic_key=%s\n%sendpoint=%s\nallowed_ip=0.0.0.0/0\nallowed_ip=::/0\npersistent_keepalive_interval=25\n",
			privKeyHex,
			cfg.Jc, cfg.Jmin, cfg.Jmax, cfg.S1, cfg.S2, cfg.H1, cfg.H2, cfg.H3, cfg.H4,
			pubKeyHex, pskLine, endpoint,
		)

		if err := dev.IpcSet(ipcConfig); err != nil {
			dev.Close()
			return fmt.Errorf("AWG IPC set: %w", err)
		}
		if err := dev.Up(); err != nil {
			dev.Close()
			return fmt.Errorf("AWG device up: %w", err)
		}
		wgDevice = nil
		awgDev = dev
		// Extract socket FDs after Up (first handshake may fail, retry will succeed after protect)
		extractBindSocketFDs(bind)
		log.Println("[vpnlib] AmneziaWG started")
	} else {
		// Standard WireGuard
		log.Println("[vpnlib] Starting standard WireGuard")
		tunDev, err := createTUN(int(tunFd), cfg.MTU)
		if err != nil {
			return fmt.Errorf("create TUN from fd %d: %w", tunFd, err)
		}
		logger := device.NewLogger(device.LogLevelVerbose, "[wg] ")
		bind := conn.NewDefaultBind()

		dev := device.NewDevice(tunDev, bind, logger)

		ipcConfig := fmt.Sprintf(
			"private_key=%s\nlisten_port=0\nreplace_peers=true\npublic_key=%s\n%sendpoint=%s\nallowed_ip=0.0.0.0/0\nallowed_ip=::/0\npersistent_keepalive_interval=25\n",
			privKeyHex, pubKeyHex, pskLine, endpoint,
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
		awgDev = nil
		// Extract socket FDs after Up (first handshake may fail, retry will succeed after protect)
		extractBindSocketFDs(bind)
	}
	return nil
}

func extractBindSocketFDs(b interface{}) {
	wgSocketV4 = -1
	wgSocketV6 = -1

	// Use unsafe to access unexported fields of StdNetBind
	v := reflect.ValueOf(b)
	if v.Kind() == reflect.Ptr {
		v = v.Elem()
	}

	for _, fieldName := range []string{"ipv4", "ipv6"} {
		field := v.FieldByName(fieldName)
		if !field.IsValid() || field.IsZero() {
			continue
		}
		// Get pointer to the unexported field via unsafe
		fieldPtr := unsafe.Pointer(field.UnsafeAddr())
		udpConn := *(**net.UDPConn)(fieldPtr)
		if udpConn == nil {
			continue
		}
		rawConn, err := udpConn.SyscallConn()
		if err != nil {
			log.Printf("[vpnlib] Failed to get syscall conn for %s: %v", fieldName, err)
			continue
		}
		var fd int32 = -1
		rawConn.Control(func(f uintptr) {
			fd = int32(f)
		})
		if fieldName == "ipv4" {
			wgSocketV4 = fd
		} else {
			wgSocketV6 = fd
		}
		log.Printf("[vpnlib] %s socket fd=%d", fieldName, fd)
	}
}

func extractVKLink(vkLink string) string {
	parts := strings.Split(vkLink, "join/")
	link := parts[len(parts)-1]
	if idx := strings.IndexAny(link, "/?#"); idx != -1 {
		link = link[:idx]
	}
	return strings.TrimSpace(link)
}

// StartVPNWithConfig starts VPN using the new ServerConfig JSON format.
// This is the new API that supports all protocols.
// Falls back to legacy StartVPN for WireGuard+TURN.
func StartVPNWithConfig(tunFd int32, serverConfigJSON string) error {
	var sc ServerConfig
	if err := json.Unmarshal([]byte(serverConfigJSON), &sc); err != nil {
		return fmt.Errorf("parse server config: %w", err)
	}

	log.Printf("[vpnlib] StartVPNWithConfig: protocol=%s address=%s turn=%v", sc.Protocol, sc.Address, sc.TURN != nil)

	// WireGuard / AmneziaWG — use legacy StartVPN path (supports both TURN and direct)
	if (sc.Protocol == "wireguard" || sc.Protocol == "amneziawg") && sc.WireGuard != nil {
		legacyCfg := config{
			Protocol:     sc.Protocol,
			PeerAddr:     sc.WireGuard.PeerAddress,
			WGPrivateKey: sc.WireGuard.PrivateKey,
			WGPublicKey:  sc.WireGuard.PublicKey,
			PresharedKey: sc.WireGuard.PresharedKey,
			WGAddress:    sc.WireGuard.WGAddress,
			WGDNS:        sc.WireGuard.DNS,
			MTU:          sc.WireGuard.MTU,
			Jc:           sc.WireGuard.Jc,
			Jmin:         sc.WireGuard.Jmin,
			Jmax:         sc.WireGuard.Jmax,
			S1:           sc.WireGuard.S1,
			S2:           sc.WireGuard.S2,
			H1:           sc.WireGuard.H1,
			H2:           sc.WireGuard.H2,
			H3:           sc.WireGuard.H3,
			H4:           sc.WireGuard.H4,
		}
		if sc.TURN != nil {
			legacyCfg.VKLink = sc.TURN.VKLink
			legacyCfg.TurnUser = sc.TURN.TurnUser
			legacyCfg.TurnPass = sc.TURN.TurnPass
			legacyCfg.TurnAddr = sc.TURN.TurnAddr
			legacyCfg.UseUDP = sc.TURN.UseUDP
			legacyCfg.NumConns = sc.TURN.NumConns
		}
		cfgJSON, _ := json.Marshal(legacyCfg)
		return StartVPN(tunFd, string(cfgJSON))
	}

	// For other protocols: use Swinger native engine
	return StartSingBox(tunFd, serverConfigJSON)
}

// GetSocketV4 returns the IPv4 UDP socket FD for VpnService.protect() on Android.
func GetSocketV4() int32 { return wgSocketV4 }

// GetSocketV6 returns the IPv6 UDP socket FD for VpnService.protect() on Android.
func GetSocketV6() int32 { return wgSocketV6 }

// ActivateWG activates the WireGuard device after sockets have been protected.
// Must be called after StartVPNWithConfig and after protecting sockets.
func ActivateWG() error {
	if pendingWGDev != nil {
		if err := pendingWGDev.Up(); err != nil {
			pendingWGDev.Close()
			pendingWGDev = nil
			return fmt.Errorf("device up: %w", err)
		}
		wgDevice = pendingWGDev
		pendingWGDev = nil
		log.Println("[vpnlib] WG activated after protect")
		return nil
	}
	if pendingAWGDev != nil {
		if err := pendingAWGDev.Up(); err != nil {
			pendingAWGDev.Close()
			pendingAWGDev = nil
			return fmt.Errorf("AWG device up: %w", err)
		}
		awgDev = pendingAWGDev
		pendingAWGDev = nil
		log.Println("[vpnlib] AWG activated after protect")
		return nil
	}
	return nil // not WG, nothing to activate
}

// PingServer tests latency to a server address. Returns milliseconds.
func PingServer(address string) (int64, error) {
	host, _, err := splitHostPort(address)
	if err != nil {
		return 0, err
	}

	start := time.Now()
	conn, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err != nil {
		// Try ICMP-like approach: just measure DNS+TCP connect
		conn2, err2 := net.DialTimeout("tcp", host+":443", 5*time.Second)
		if err2 != nil {
			return 0, fmt.Errorf("ping %s: %w", address, err)
		}
		conn2.Close()
	} else {
		conn.Close()
	}
	return time.Since(start).Milliseconds(), nil
}

// ParseServerURI parses protocol URIs (vless://, ss://, trojan://, etc.)
// and returns a ServerConfig JSON string.
func ParseServerURI(uri string) (string, error) {
	// TODO: implement URI parsing for each protocol
	// vless://uuid@host:port?type=ws&security=tls&sni=example.com#name
	// ss://method:password@host:port#name
	// trojan://password@host:port?sni=example.com#name
	// vmess://base64json
	return "", fmt.Errorf("URI parsing not yet implemented")
}

func splitHostPort(addr string) (string, int, error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return "", 0, err
	}
	port := 0
	fmt.Sscanf(portStr, "%d", &port)
	return host, port, nil
}

func b64ToHex(b64 string) (string, error) {
	// WireGuard keys are 32 bytes in base64
	b64 = strings.TrimSpace(b64)

	// Normalize: convert URL-safe chars to standard base64
	normalized := strings.NewReplacer("-", "+", "_", "/").Replace(b64)

	// Try with padding
	b, err := base64.StdEncoding.DecodeString(normalized)
	if err != nil {
		// Try without padding
		b, err = base64.RawStdEncoding.DecodeString(strings.TrimRight(normalized, "="))
		if err != nil {
			return "", fmt.Errorf("decode base64: %w", err)
		}
	}

	if len(b) != 32 {
		return "", fmt.Errorf("key must be 32 bytes, got %d", len(b))
	}

	return hex.EncodeToString(b), nil
}
