package vpnlib

// Swinger — tun2socks via gvisor netstack
// Reads raw IP packets from TUN fd, reassembles TCP/UDP,
// proxies through ProxyDialer.

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

const (
	nicID    = 1
	chanSize = 256
	tunMTU   = 1500
)

// StartTun2Socks starts a userspace TCP/IP stack that reads from TUN fd
// and proxies all TCP connections through the ProxyDialer.
func StartTun2Socks(ctx context.Context, tunFd int32, dialer ProxyDialer) error {
	log.Printf("[tun2socks] Starting gvisor netstack, tunFd=%d", tunFd)

	// Create single os.File for the TUN fd (avoid double-close from multiple os.NewFile)
	tunFile := os.NewFile(uintptr(tunFd), "/dev/utun")
	if tunFile == nil {
		return fmt.Errorf("failed to open TUN fd %d", tunFd)
	}

	// Create gvisor network stack
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})

	// Create channel endpoint (bridge between TUN and gvisor)
	ep := channel.New(chanSize, tunMTU, "")
	if tcpipErr := s.CreateNIC(nicID, ep); tcpipErr != nil {
		s.Close()
		return fmt.Errorf("create NIC: %v", tcpipErr)
	}

	// Route all traffic through our NIC
	s.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: nicID},
		{Destination: header.IPv6EmptySubnet, NIC: nicID},
	})

	// Enable promiscuous + spoofing (accept all packets)
	s.SetPromiscuousMode(nicID, true)
	s.SetSpoofing(nicID, true)

	// Set TCP forwarder — intercept all TCP connections
	tcpFwd := tcp.NewForwarder(s, 0, 65535, func(r *tcp.ForwarderRequest) {
		id := r.ID()
		destAddr := fmt.Sprintf("%s:%d", id.LocalAddress.String(), id.LocalPort)

		var wq waiter.Queue
		ep, tcpipErr := r.CreateEndpoint(&wq)
		if tcpipErr != nil {
			log.Printf("[tun2socks] TCP create endpoint %s: %v", destAddr, tcpipErr)
			r.Complete(true) // RST
			return
		}
		r.Complete(false) // ACK

		localConn := gonet.NewTCPConn(&wq, ep)

		go func() {
			defer localConn.Close()

			remoteConn, err := dialer.DialTCP(ctx, destAddr)
			if err != nil {
				log.Printf("[tun2socks] Dial %s: %v", destAddr, err)
				return
			}
			defer remoteConn.Close()

			// Close both connections when context is cancelled
			go func() {
				<-ctx.Done()
				localConn.Close()
				remoteConn.Close()
			}()

			// Bidirectional relay
			var wg sync.WaitGroup
			wg.Add(2)
			go func() {
				defer wg.Done()
				io.Copy(remoteConn, localConn)
			}()
			go func() {
				defer wg.Done()
				io.Copy(localConn, remoteConn)
			}()
			wg.Wait()
		}()
	})
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpFwd.HandlePacket)

	// UDP forwarder — handle DNS and other UDP (forward to upstream directly)
	udpFwd := udp.NewForwarder(s, func(r *udp.ForwarderRequest) {
		id := r.ID()
		destAddr := fmt.Sprintf("%s:%d", id.LocalAddress.String(), id.LocalPort)

		var wq waiter.Queue
		ep, tcpipErr := r.CreateEndpoint(&wq)
		if tcpipErr != nil {
			return
		}

		localConn := gonet.NewUDPConn(&wq, ep)
		go handleUDP(ctx, localConn, destAddr)
	})
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udpFwd.HandlePacket)

	// TUN reader goroutine — read IP packets from TUN fd, inject into gvisor
	go tunReader(ctx, tunFile, ep)

	// TUN writer goroutine — read packets from gvisor, write to TUN fd
	go tunWriter(ctx, tunFile, ep)

	// Cleanup goroutine — close stack when context is done
	go func() {
		<-ctx.Done()
		log.Println("[tun2socks] Shutting down gvisor stack")
		ep.Close()
		s.Close()
	}()

	log.Println("[tun2socks] gvisor netstack started")
	return nil
}

// tunReader reads raw IP packets from TUN fd and injects them into gvisor stack
func tunReader(ctx context.Context, tunFile *os.File, ep *channel.Endpoint) {
	buf := make([]byte, tunMTU+4) // +4 for iOS utun AF header
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Set read deadline so we can check context periodically
		tunFile.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		n, err := tunFile.Read(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if os.IsTimeout(err) {
				continue
			}
			continue
		}

		// iOS utun prepends 4-byte AF header
		if n <= 4 {
			continue
		}

		// Copy packet (buf is reused on next read)
		pkt := make([]byte, n-4)
		copy(pkt, buf[4:n])

		// Determine protocol
		var proto tcpip.NetworkProtocolNumber
		if len(pkt) > 0 {
			switch pkt[0] >> 4 {
			case 4:
				proto = header.IPv4ProtocolNumber
			case 6:
				proto = header.IPv6ProtocolNumber
			default:
				continue
			}
		}

		// Inject into gvisor
		pkb := stack.NewPacketBuffer(stack.PacketBufferOptions{
			Payload: buffer.MakeWithData(pkt),
		})
		ep.InjectInbound(proto, pkb)
		pkb.DecRef()
	}
}

// tunWriter reads packets from gvisor and writes them back to TUN fd
func tunWriter(ctx context.Context, tunFile *os.File, ep *channel.Endpoint) {
	// Reusable output buffer (single goroutine, no concurrency)
	outBuf := make([]byte, 4+tunMTU)

	for {
		pkb := ep.ReadContext(ctx)
		if pkb == nil {
			return // context done
		}

		// Get raw packet data
		data := pkb.ToView().AsSlice()
		pkb.DecRef()

		if len(data) == 0 {
			continue
		}

		// Prepend iOS utun AF header
		var af byte = 2 // AF_INET
		if data[0]>>4 == 6 {
			af = 30 // AF_INET6
		}

		// Reuse buffer
		if len(data)+4 > cap(outBuf) {
			outBuf = make([]byte, len(data)+4)
		}
		out := outBuf[:4+len(data)]
		out[0] = 0
		out[1] = 0
		out[2] = 0
		out[3] = af
		copy(out[4:], data)

		tunFile.Write(out)
	}
}

// handleUDP forwards UDP packets directly (for DNS etc)
func handleUDP(ctx context.Context, localConn *gonet.UDPConn, destAddr string) {
	defer localConn.Close()

	remote, err := net.DialTimeout("udp", destAddr, 5*time.Second)
	if err != nil {
		return
	}
	defer remote.Close()

	// Close connections on context cancel
	go func() {
		<-ctx.Done()
		localConn.Close()
		remote.Close()
	}()

	// Relay
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		buf := make([]byte, 4096)
		for {
			n, err := localConn.Read(buf)
			if err != nil {
				return
			}
			remote.Write(buf[:n])
		}
	}()
	go func() {
		defer wg.Done()
		buf := make([]byte, 4096)
		for {
			n, err := remote.Read(buf)
			if err != nil {
				return
			}
			localConn.Write(buf[:n])
		}
	}()
	wg.Wait()
}
