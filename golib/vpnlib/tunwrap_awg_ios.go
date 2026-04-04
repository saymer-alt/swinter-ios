//go:build ios

package vpnlib

// AWG TUN wrapper for iOS — adapts our iosTUN to amneziawg-go's tun.Device interface.

import (
	"os"
	"sync"

	awgTun "github.com/amnezia-vpn/amneziawg-go/tun"
)

type iosAWGTUN struct {
	fd     *os.File
	mtu    int
	events chan awgTun.Event
	closer sync.Once
}

func createAWGTUN(fd int, mtu int) (awgTun.Device, error) {
	return &iosAWGTUN{
		fd:     os.NewFile(uintptr(fd), "/dev/utun"),
		mtu:    mtu,
		events: make(chan awgTun.Event, 1),
	}, nil
}

func (t *iosAWGTUN) File() *os.File { return t.fd }
func (t *iosAWGTUN) Name() (string, error) { return "utun-awg", nil }
func (t *iosAWGTUN) MTU() (int, error) { return t.mtu, nil }
func (t *iosAWGTUN) Events() <-chan awgTun.Event { return t.events }
func (t *iosAWGTUN) BatchSize() int { return 1 }

func (t *iosAWGTUN) Close() error {
	var err error
	t.closer.Do(func() {
		close(t.events)
		err = t.fd.Close()
	})
	return err
}

func (t *iosAWGTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	// iOS utun prepends 4-byte AF header
	buf := bufs[0][offset-utunHeaderSize : offset+t.mtu]
	n, err := t.fd.Read(buf)
	if err != nil {
		return 0, err
	}
	if n <= utunHeaderSize {
		sizes[0] = 0
		return 1, nil
	}
	// Strip AF header
	copy(bufs[0][offset:], buf[utunHeaderSize:n])
	sizes[0] = n - utunHeaderSize
	return 1, nil
}

func (t *iosAWGTUN) Write(bufs [][]byte, offset int) (int, error) {
	for _, buf := range bufs {
		pkt := buf[offset:]
		if len(pkt) == 0 {
			continue
		}
		// Determine AF from IP version
		var af byte = 2 // AF_INET
		if pkt[0]>>4 == 6 {
			af = 30 // AF_INET6
		}
		header := [utunHeaderSize]byte{0, 0, 0, af}
		full := make([]byte, utunHeaderSize+len(pkt))
		copy(full, header[:])
		copy(full[utunHeaderSize:], pkt)
		if _, err := t.fd.Write(full); err != nil {
			return 0, err
		}
	}
	return len(bufs), nil
}
