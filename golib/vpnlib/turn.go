package vpnlib

// TURN proxy logic.
//
// The VK credential-fetching flow and the DTLS+TURN client pattern are
// vendored from https://github.com/cacggghp/vk-turn-proxy (MIT, Pion
// community). Slider-captcha bypass lives in vk_captcha.go — also theirs.
// Go read that repo. It is the actual brain of this feature.

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cbeuw/connutil"
	"github.com/google/uuid"
	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/pion/logging"
	"github.com/pion/turn/v5"
)

type getCredsFunc func(string) (string, string, string, error)

type turnParams struct {
	host     string
	port     string
	link     string
	udp      bool
	getCreds getCredsFunc
}

// ============================================================================
// VK Credential Fetching
// ============================================================================

func getVkCreds(link string) (user string, pass string, addr string, retErr error) {
	// Single HTTP client — force IPv4 to prevent ip mismatch from IPv4/IPv6 mixing
	dialer := &net.Dialer{
		Timeout: 10 * time.Second,
	}
	client := &http.Client{
		Timeout: 20 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				// Force TCP4 — prevents VK "ip mismatch" caused by IPv6
				return dialer.DialContext(ctx, "tcp4", addr)
			},
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 100,
			IdleConnTimeout:     90 * time.Second,
			DisableKeepAlives:   false,
			ForceAttemptHTTP2:   false,
		},
	}
	defer client.CloseIdleConnections()

	// Browser profile for the whole session — UA + sec-ch-ua + browser_fp
	// must all stay consistent or VK will flag the captcha session.
	profile := getRandomVkProfile()

	doRequest := func(data string, url string) (resp map[string]interface{}, err error) {
		req, err := http.NewRequest("POST", url, bytes.NewBuffer([]byte(data)))
		if err != nil {
			return nil, err
		}
		applyBrowserProfile(req, profile)
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

		httpResp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer httpResp.Body.Close()

		body, err := io.ReadAll(httpResp.Body)
		if err != nil {
			return nil, err
		}

		err = json.Unmarshal(body, &resp)
		if err != nil {
			return nil, fmt.Errorf("json unmarshal: %w (body: %s)", err, string(body[:min(len(body), 200)]))
		}
		return resp, nil
	}

	// Helper to safely extract string from nested map
	getString := func(m map[string]interface{}, keys ...string) (string, error) {
		var current interface{} = m
		for _, key := range keys {
			cm, ok := current.(map[string]interface{})
			if !ok {
				return "", fmt.Errorf("key %q: not a map (got %T)", key, current)
			}
			current, ok = cm[key]
			if !ok {
				return "", fmt.Errorf("key %q not found in response: %v", key, cm)
			}
		}
		s, ok := current.(string)
		if !ok {
			return "", fmt.Errorf("value is not string: %T = %v", current, current)
		}
		return s, nil
	}

	var resp map[string]interface{}

	// Step 1: Get anonymous token
	data := "client_secret=QbYic1K3lEV5kTGiqlq2&client_id=6287487&scopes=audio_anonymous%2Cvideo_anonymous%2Cphotos_anonymous%2Cprofile_anonymous&isApiOauthAnonymEnabled=false&version=1&app_id=6287487"
	url := "https://login.vk.ru/?act=get_anonym_token"
	resp, err := doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("step1: %w", err)
	}
	token1, err := getString(resp, "data", "access_token")
	if err != nil {
		return "", "", "", fmt.Errorf("step1 parse: %w (resp: %v)", err, resp)
	}

	// Step 2: Get anonymous access token payload
	data = fmt.Sprintf("access_token=%s", token1)
	url = "https://api.vk.ru/method/calls.getAnonymousAccessTokenPayload?v=5.264&client_id=6287487"
	resp, err = doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("step2: %w", err)
	}
	token2, err := getString(resp, "response", "payload")
	if err != nil {
		return "", "", "", fmt.Errorf("step2 parse: %w (resp: %v)", err, resp)
	}

	// Step 3: Get messages token
	data = fmt.Sprintf("client_id=6287487&token_type=messages&payload=%s&client_secret=QbYic1K3lEV5kTGiqlq2&version=1&app_id=6287487", token2)
	url = "https://login.vk.ru/?act=get_anonym_token"
	resp, err = doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("step3: %w", err)
	}
	token3, err := getString(resp, "data", "access_token")
	if err != nil {
		return "", "", "", fmt.Errorf("step3 parse: %w (resp: %v)", err, resp)
	}

	// Step 4: Get call anonymous token — may return a captcha challenge.
	// Retry loop with slider-POC auto-solve (vendored from
	// cacggghp/vk-turn-proxy). VK returns error_code 14 with a redirect_uri
	// that hosts a PoW puzzle + slider captcha; we bootstrap it, solve, and
	// retry with success_token + captcha_ts + captcha_attempt.
	url = "https://api.vk.ru/method/calls.getAnonymousToken?v=5.264"
	baseData := fmt.Sprintf("vk_join_link=https://vk.com/call/join/%s&name=123&access_token=%s", link, token3)
	data = baseData

	var token4 string
	for attempt := 0; attempt < 3; attempt++ {
		resp, err = doRequest(data, url)
		if err != nil {
			return "", "", "", fmt.Errorf("step4: %w", err)
		}

		if errObj, hasErr := resp["error"].(map[string]interface{}); hasErr {
			captchaErr := parseVkCaptchaError(errObj)
			if captchaErr == nil || !captchaErr.isCaptchaError() {
				return "", "", "", fmt.Errorf("step4 VK error: %v", errObj)
			}

			log.Printf("[VK] captcha challenge on step4 (attempt %d), solving...", attempt+1)
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			successToken, solveErr := solveVkCaptcha(ctx, captchaErr, client, profile)
			cancel()
			if solveErr != nil {
				log.Printf("[VK] captcha solve failed (attempt %d): %v", attempt+1, solveErr)
				if attempt == 2 {
					return "", "", "", fmt.Errorf("step4 captcha solve failed: %w", solveErr)
				}
				continue
			}

			captchaAttempt := captchaErr.CaptchaAttempt
			if captchaAttempt == "" || captchaAttempt == "0" {
				captchaAttempt = "1"
			}
			data = fmt.Sprintf(
				"%s&captcha_key=&captcha_sid=%s&is_sound_captcha=0&success_token=%s&captcha_ts=%s&captcha_attempt=%s",
				baseData,
				captchaErr.CaptchaSid,
				neturl.QueryEscape(successToken),
				captchaErr.CaptchaTs,
				captchaAttempt,
			)
			continue
		}

		token4, err = getString(resp, "response", "token")
		if err != nil {
			return "", "", "", fmt.Errorf("step4 parse: %w (resp: %v)", err, resp)
		}
		break
	}
	if token4 == "" {
		return "", "", "", fmt.Errorf("step4: token empty after captcha retries")
	}

	// Step 5: OK auth
	data = fmt.Sprintf("session_data=%%7B%%22version%%22%%3A2%%2C%%22device_id%%22%%3A%%22%s%%22%%2C%%22client_version%%22%%3A1.1%%2C%%22client_type%%22%%3A%%22SDK_JS%%22%%7D&method=auth.anonymLogin&format=JSON&application_key=CGMMEJLGDIHBABABA", uuid.New())
	url = "https://calls.okcdn.ru/fb.do"
	resp, err = doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("step5: %w", err)
	}
	token5, err := getString(resp, "session_key")
	if err != nil {
		return "", "", "", fmt.Errorf("step5 parse: %w (resp: %v)", err, resp)
	}

	// Step 6: Join call and get TURN credentials
	data = fmt.Sprintf("joinLink=%s&isVideo=false&protocolVersion=5&anonymToken=%s&method=vchat.joinConversationByLink&format=JSON&application_key=CGMMEJLGDIHBABABA&session_key=%s", link, token4, token5)
	url = "https://calls.okcdn.ru/fb.do"
	resp, err = doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("step6: %w", err)
	}

	turnUser, err := getString(resp, "turn_server", "username")
	if err != nil {
		return "", "", "", fmt.Errorf("step6 parse username: %w (resp: %v)", err, resp)
	}
	turnPass, err := getString(resp, "turn_server", "credential")
	if err != nil {
		return "", "", "", fmt.Errorf("step6 parse credential: %w", err)
	}
	turnServer, ok := resp["turn_server"].(map[string]interface{})
	if !ok {
		return "", "", "", fmt.Errorf("step6: no turn_server in resp")
	}
	urls, ok := turnServer["urls"].([]interface{})
	if !ok || len(urls) == 0 {
		return "", "", "", fmt.Errorf("step6: no urls in turn_server")
	}
	turnURL, ok := urls[0].(string)
	if !ok {
		return "", "", "", fmt.Errorf("step6: url is not string")
	}

	_ = turnUser
	_ = turnPass

	clean := strings.Split(turnURL, "?")[0]
	address := strings.TrimPrefix(strings.TrimPrefix(clean, "turn:"), "turns:")

	log.Printf("[turn] Got credentials, TURN server: %s", address)
	return turnUser, turnPass, address, nil
}

// ============================================================================
// DTLS Connection
// ============================================================================

func dtlsFunc(ctx context.Context, conn net.PacketConn, peer *net.UDPAddr) (net.Conn, error) {
	certificate, err := selfsign.GenerateSelfSigned()
	if err != nil {
		return nil, err
	}
	config := &dtls.Config{
		Certificates:          []tls.Certificate{certificate},
		InsecureSkipVerify:    true,
		ExtendedMasterSecret:  dtls.RequireExtendedMasterSecret,
		CipherSuites:          []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256},
		ConnectionIDGenerator: dtls.OnlySendCIDGenerator(),
	}
	ctx1, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	dtlsConn, err := dtls.Client(conn, peer, config)
	if err != nil {
		return nil, err
	}
	if err := dtlsConn.HandshakeContext(ctx1); err != nil {
		return nil, err
	}
	return dtlsConn, nil
}

// ============================================================================
// One DTLS connection loop
// ============================================================================

func oneDtlsConnection(ctx context.Context, peer *net.UDPAddr, listenConn net.PacketConn, connchan chan<- net.PacketConn, okchan chan<- struct{}, c chan<- error) {
	var err error
	defer func() { c <- err }()

	dtlsctx, dtlscancel := context.WithCancel(ctx)
	defer dtlscancel()

	var conn1, conn2 net.PacketConn
	conn1, conn2 = connutil.AsyncPacketPipe()

	go func() {
		for {
			select {
			case <-dtlsctx.Done():
				return
			case connchan <- conn2:
			}
		}
	}()

	dtlsConn, err1 := dtlsFunc(dtlsctx, conn1, peer)
	if err1 != nil {
		err = fmt.Errorf("DTLS connect: %s", err1)
		return
	}
	defer func() {
		dtlsConn.Close()
		log.Println("[turn] DTLS connection closed")
	}()

	log.Println("[turn] DTLS connection established!")

	if okchan != nil {
		go func() {
			for {
				select {
				case <-dtlsctx.Done():
					return
				case okchan <- struct{}{}:
				}
			}
		}()
	}

	wg := sync.WaitGroup{}
	wg.Add(2)
	context.AfterFunc(dtlsctx, func() {
		listenConn.SetDeadline(time.Now())
		dtlsConn.SetDeadline(time.Now())
	})

	var addr atomic.Value

	// listenConn → dtlsConn
	go func() {
		defer wg.Done()
		defer dtlscancel()
		buf := make([]byte, 1600)
		for {
			select {
			case <-dtlsctx.Done():
				return
			default:
			}
			n, addr1, err1 := listenConn.ReadFrom(buf)
			if err1 != nil {
				return
			}
			addr.Store(addr1)
			if _, err1 = dtlsConn.Write(buf[:n]); err1 != nil {
				return
			}
		}
	}()

	// dtlsConn → listenConn
	go func() {
		defer wg.Done()
		defer dtlscancel()
		buf := make([]byte, 1600)
		for {
			select {
			case <-dtlsctx.Done():
				return
			default:
			}
			n, err1 := dtlsConn.Read(buf)
			if err1 != nil {
				return
			}
			addr1, ok := addr.Load().(net.Addr)
			if !ok {
				return
			}
			if _, err1 = listenConn.WriteTo(buf[:n], addr1); err1 != nil {
				return
			}
		}
	}()

	wg.Wait()
	listenConn.SetDeadline(time.Time{})
	dtlsConn.SetDeadline(time.Time{})
}

// ============================================================================
// TURN connection
// ============================================================================

type connectedUDPConn struct {
	*net.UDPConn
}

func (c *connectedUDPConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	return c.Write(p)
}

func oneTurnConnection(ctx context.Context, turnP *turnParams, peer *net.UDPAddr, conn2 net.PacketConn, c chan<- error) {
	var err error
	defer func() { c <- err }()

	user, pass, url, err1 := turnP.getCreds(turnP.link)
	if err1 != nil {
		err = fmt.Errorf("TURN creds: %s", err1)
		return
	}

	urlhost, urlport, err1 := net.SplitHostPort(url)
	if err1 != nil {
		err = fmt.Errorf("parse TURN addr: %s", err1)
		return
	}
	if turnP.host != "" {
		urlhost = turnP.host
	}
	if turnP.port != "" {
		urlport = turnP.port
	}

	turnServerAddr := net.JoinHostPort(urlhost, urlport)
	turnServerUdpAddr, err1 := net.ResolveUDPAddr("udp", turnServerAddr)
	if err1 != nil {
		err = fmt.Errorf("resolve TURN: %s", err1)
		return
	}
	turnServerAddr = turnServerUdpAddr.String()
	log.Printf("[turn] TURN server: %s", turnServerAddr)

	var turnConn net.PacketConn
	ctx1, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	if turnP.udp {
		c, err2 := net.DialUDP("udp", nil, turnServerUdpAddr)
		if err2 != nil {
			err = fmt.Errorf("dial TURN UDP: %s", err2)
			return
		}
		defer c.Close()
		turnConn = &connectedUDPConn{c}
	} else {
		d := net.Dialer{}
		c, err2 := d.DialContext(ctx1, "tcp", turnServerAddr)
		if err2 != nil {
			err = fmt.Errorf("dial TURN TCP: %s", err2)
			return
		}
		defer c.Close()
		turnConn = turn.NewSTUNConn(c)
	}

	var addrFamily turn.RequestedAddressFamily
	if peer.IP.To4() != nil {
		addrFamily = turn.RequestedAddressFamilyIPv4
	} else {
		addrFamily = turn.RequestedAddressFamilyIPv6
	}

	cfg := &turn.ClientConfig{
		STUNServerAddr:         turnServerAddr,
		TURNServerAddr:         turnServerAddr,
		Conn:                   turnConn,
		Username:               user,
		Password:               pass,
		RequestedAddressFamily: addrFamily,
		LoggerFactory:          logging.NewDefaultLoggerFactory(),
	}

	client, err1 := turn.NewClient(cfg)
	if err1 != nil {
		err = fmt.Errorf("TURN client: %s", err1)
		return
	}
	defer client.Close()

	if err1 = client.Listen(); err1 != nil {
		err = fmt.Errorf("TURN listen: %s", err1)
		return
	}

	relayConn, err1 := client.Allocate()
	if err1 != nil {
		err = fmt.Errorf("TURN allocate: %s", err1)
		return
	}
	defer relayConn.Close()

	log.Printf("[turn] Relay address: %s", relayConn.LocalAddr())

	wg := sync.WaitGroup{}
	wg.Add(2)
	turnctx, turncancel := context.WithCancel(context.Background())
	context.AfterFunc(turnctx, func() {
		relayConn.SetDeadline(time.Now())
		conn2.SetDeadline(time.Now())
	})

	var addr atomic.Value

	// conn2 → relay
	go func() {
		defer wg.Done()
		defer turncancel()
		buf := make([]byte, 1600)
		for {
			select {
			case <-turnctx.Done():
				return
			default:
			}
			n, addr1, err1 := conn2.ReadFrom(buf)
			if err1 != nil {
				return
			}
			addr.Store(addr1)
			if _, err1 = relayConn.WriteTo(buf[:n], peer); err1 != nil {
				return
			}
		}
	}()

	// relay → conn2
	go func() {
		defer wg.Done()
		defer turncancel()
		buf := make([]byte, 1600)
		for {
			select {
			case <-turnctx.Done():
				return
			default:
			}
			n, _, err1 := relayConn.ReadFrom(buf)
			if err1 != nil {
				return
			}
			addr1, ok := addr.Load().(net.Addr)
			if !ok {
				return
			}
			if _, err1 = conn2.WriteTo(buf[:n], addr1); err1 != nil {
				return
			}
		}
	}()

	wg.Wait()
	relayConn.SetDeadline(time.Time{})
	conn2.SetDeadline(time.Time{})
}

// ============================================================================
// Connection loop managers
// ============================================================================

func oneDtlsConnectionLoop(ctx context.Context, peer *net.UDPAddr, listenConnChan <-chan net.PacketConn, connchan chan<- net.PacketConn, okchan chan<- struct{}) {
	for {
		select {
		case <-ctx.Done():
			return
		case listenConn := <-listenConnChan:
			c := make(chan error)
			go oneDtlsConnection(ctx, peer, listenConn, connchan, okchan, c)
			if err := <-c; err != nil {
				log.Printf("[turn] DTLS error: %s", err)
			}
		}
	}
}

func oneTurnConnectionLoop(ctx context.Context, turnP *turnParams, peer *net.UDPAddr, connchan <-chan net.PacketConn, t <-chan time.Time) {
	for {
		select {
		case <-ctx.Done():
			return
		case conn2 := <-connchan:
			select {
			case <-t:
				c := make(chan error)
				go oneTurnConnection(ctx, turnP, peer, conn2, c)
				if err := <-c; err != nil {
					log.Printf("[turn] TURN error: %s", err)
				}
			default:
			}
		}
	}
}

// ============================================================================
// Main TURN proxy entry point
// ============================================================================

func startTurnProxy(ctx context.Context, params *turnParams, peer *net.UDPAddr, listenAddr string, numConns int, readyCh chan<- struct{}) {
	log.Printf("[turn] Starting proxy: listen=%s peer=%s conns=%d", listenAddr, peer, numConns)

	listenConn, err := net.ListenPacket("udp", listenAddr)
	if err != nil {
		log.Printf("[turn] Failed to listen on %s: %s", listenAddr, err)
		return
	}
	context.AfterFunc(ctx, func() {
		listenConn.Close()
	})

	listenConnChan := make(chan net.PacketConn)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case listenConnChan <- listenConn:
			}
		}
	}()

	wg := sync.WaitGroup{}
	t := time.Tick(100 * time.Millisecond)

	// First connection: DTLS + TURN with ready signal
	okchan := make(chan struct{})
	connchan := make(chan net.PacketConn)

	wg.Add(2)
	go func() {
		defer wg.Done()
		oneDtlsConnectionLoop(ctx, peer, listenConnChan, connchan, okchan)
	}()
	go func() {
		defer wg.Done()
		oneTurnConnectionLoop(ctx, params, peer, connchan, t)
	}()

	// Signal ready when first connection establishes
	select {
	case <-okchan:
		select {
		case readyCh <- struct{}{}:
		default:
		}
	case <-ctx.Done():
		wg.Wait()
		return
	}

	// Additional connections
	for i := 0; i < numConns-1; i++ {
		connchan := make(chan net.PacketConn)
		wg.Add(2)
		go func() {
			defer wg.Done()
			oneDtlsConnectionLoop(ctx, peer, listenConnChan, connchan, nil)
		}()
		go func() {
			defer wg.Done()
			oneTurnConnectionLoop(ctx, params, peer, connchan, t)
		}()
	}

	wg.Wait()
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

