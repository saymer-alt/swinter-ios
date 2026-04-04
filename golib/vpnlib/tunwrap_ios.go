//go:build ios

package vpnlib

// Custom TUN for iOS Network Extension.
// Standard wireguard-go CreateTUNFromFile calls ioctl (set MTU) which
// NE sandbox blocks. This wrapper handles utun 4-byte AF header manually.

import (
	"os"
	"sync"
	"syscall"

	"golang.zx2c4.com/wireguard/tun"
)

const utunHeaderSize = 4

type iosTUN struct {
	fd     *os.File
	mtu    int
	events chan tun.Event
	closer sync.Once
}

func createTUN(fd int, mtu int) (tun.Device, error) {
	return &iosTUN{
		fd:     os.NewFile(uintptr(fd), "/dev/utun"),
		mtu:    mtu,
		events: make(chan tun.Event, 1),
	}, nil
}

func (t *iosTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	// utun kernel prepends 4 bytes: [0x00, 0x00, 0x00, AF_INET|AF_INET6]
	// WireGuard wants IP packet at bufs[0][offset]
	// Read into [offset-4:] so AF header lands before offset
	start := offset - utunHeaderSize
	if start < 0 {
		start = 0
	}
	n, err := t.fd.Read(bufs[0][start:])
	if err != nil {
		return 0, err
	}
	if n <= utunHeaderSize {
		return 0, nil
	}
	sizes[0] = n - utunHeaderSize
	return 1, nil
}

func (t *iosTUN) Write(bufs [][]byte, offset int) (int, error) {
	written := 0
	for _, buf := range bufs {
		if offset < utunHeaderSize || len(buf) <= offset {
			continue
		}
		// Prepend 4-byte utun header with AF family
		var af byte = syscall.AF_INET
		if buf[offset]>>4 == 6 {
			af = syscall.AF_INET6
		}
		buf[offset-4] = 0
		buf[offset-3] = 0
		buf[offset-2] = 0
		buf[offset-1] = af

		_, err := t.fd.Write(buf[offset-utunHeaderSize:])
		if err != nil {
			return written, err
		}
		written++
	}
	return written, nil
}

func (t *iosTUN) File() *os.File           { return t.fd }
func (t *iosTUN) MTU() (int, error)       { return t.mtu, nil }
func (t *iosTUN) Name() (string, error)    { return "utun", nil }
func (t *iosTUN) Events() <-chan tun.Event { return t.events }
func (t *iosTUN) BatchSize() int           { return 1 }

func (t *iosTUN) Close() error {
	var err error
	t.closer.Do(func() {
		close(t.events)
		err = t.fd.Close()
	})
	return err
}
