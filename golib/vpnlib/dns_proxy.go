package vpnlib

// Swinger — Local DNS proxy
// Forwards DNS queries to upstream resolver (bypassing TUN).
// Required because TUN captures all UDP including DNS, but startPacketForwarding drops them.

import (
	"context"
	"log"
	"net"
	"sync"
	"time"
)

var (
	dnsMu     sync.Mutex
	dnsCancel context.CancelFunc
)

const (
	dnsListenAddr   = "127.0.0.1:53"
	dnsUpstream     = "1.1.1.1:53"
	dnsUpstreamAlt  = "8.8.8.8:53"
	dnsMaxSize      = 4096
	dnsTimeout      = 5 * time.Second
)

// StartDNSProxy starts a local UDP DNS forwarder.
// Listens on 127.0.0.1:53, forwards queries to upstream DNS.
func StartDNSProxy(ctx context.Context) error {
	dnsMu.Lock()
	defer dnsMu.Unlock()

	addr, err := net.ResolveUDPAddr("udp", dnsListenAddr)
	if err != nil {
		return err
	}

	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		// Port 53 might need root — try high port
		addr2, _ := net.ResolveUDPAddr("udp", "127.0.0.1:15353")
		conn, err = net.ListenUDP("udp", addr2)
		if err != nil {
			return err
		}
		log.Printf("[dns-proxy] Listening on 127.0.0.1:15353 (port 53 unavailable)")
	} else {
		log.Printf("[dns-proxy] Listening on %s", dnsListenAddr)
	}

	dnsCtx, cancel := context.WithCancel(ctx)
	dnsCancel = cancel

	go func() {
		defer conn.Close()
		buf := make([]byte, dnsMaxSize)
		for {
			select {
			case <-dnsCtx.Done():
				return
			default:
			}

			conn.SetReadDeadline(time.Now().Add(1 * time.Second))
			n, clientAddr, err := conn.ReadFromUDP(buf)
			if err != nil {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					continue
				}
				if dnsCtx.Err() != nil {
					return
				}
				continue
			}

			// Copy query before passing to goroutine (buf is reused)
			query := make([]byte, n)
			copy(query, buf[:n])
			go forwardDNS(conn, clientAddr, query)
		}
	}()

	return nil
}

func StopDNSProxy() {
	dnsMu.Lock()
	defer dnsMu.Unlock()
	if dnsCancel != nil {
		dnsCancel()
		dnsCancel = nil
	}
}

func forwardDNS(listener *net.UDPConn, clientAddr *net.UDPAddr, query []byte) {
	// Try primary upstream
	response, err := dnsQuery(dnsUpstream, query)
	if err != nil {
		// Fallback
		response, err = dnsQuery(dnsUpstreamAlt, query)
		if err != nil {
			log.Printf("[dns-proxy] Both upstreams failed: %v", err)
			return
		}
	}

	listener.WriteToUDP(response, clientAddr)
}

func dnsQuery(upstream string, query []byte) ([]byte, error) {
	conn, err := net.DialTimeout("udp", upstream, dnsTimeout)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	conn.SetDeadline(time.Now().Add(dnsTimeout))
	if _, err := conn.Write(query); err != nil {
		return nil, err
	}

	buf := make([]byte, dnsMaxSize)
	n, err := conn.Read(buf)
	if err != nil {
		return nil, err
	}

	return buf[:n], nil
}
