//go:build android

package vpnlib

// Android TUN wrapper. Android TUN devices deliver raw IP packets
// without any header (unlike iOS utun which prepends 4-byte AF header).

import (
	"os"
	"sync"

	"golang.zx2c4.com/wireguard/tun"
)

type androidTUN struct {
	fd     *os.File
	mtu    int
	events chan tun.Event
	closer sync.Once
}

func createTUN(fd int, mtu int) (tun.Device, error) {
	return &androidTUN{
		fd:     os.NewFile(uintptr(fd), "/dev/tun"),
		mtu:    mtu,
		events: make(chan tun.Event, 1),
	}, nil
}

func (t *androidTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	n, err := t.fd.Read(bufs[0][offset:])
	if err != nil {
		return 0, err
	}
	sizes[0] = n
	return 1, nil
}

func (t *androidTUN) Write(bufs [][]byte, offset int) (int, error) {
	written := 0
	for _, buf := range bufs {
		if len(buf) <= offset {
			continue
		}
		_, err := t.fd.Write(buf[offset:])
		if err != nil {
			return written, err
		}
		written++
	}
	return written, nil
}

func (t *androidTUN) File() *os.File           { return t.fd }
func (t *androidTUN) MTU() (int, error)        { return t.mtu, nil }
func (t *androidTUN) Name() (string, error)    { return "tun0", nil }
func (t *androidTUN) Events() <-chan tun.Event { return t.events }
func (t *androidTUN) BatchSize() int           { return 1 }

func (t *androidTUN) Close() error {
	var err error
	t.closer.Do(func() {
		close(t.events)
		err = t.fd.Close()
	})
	return err
}
