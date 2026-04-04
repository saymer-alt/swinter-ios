//go:build android

package vpnlib

import (
	"os"
	"sync"

	awgTun "github.com/amnezia-vpn/amneziawg-go/tun"
)

type androidAWGTUN struct {
	fd     *os.File
	mtu    int
	events chan awgTun.Event
	closer sync.Once
}

func createAWGTUN(fd int, mtu int) (awgTun.Device, error) {
	return &androidAWGTUN{
		fd:     os.NewFile(uintptr(fd), "/dev/tun"),
		mtu:    mtu,
		events: make(chan awgTun.Event, 1),
	}, nil
}

func (t *androidAWGTUN) File() *os.File { return t.fd }
func (t *androidAWGTUN) Name() (string, error) { return "tun-awg", nil }
func (t *androidAWGTUN) MTU() (int, error) { return t.mtu, nil }
func (t *androidAWGTUN) Events() <-chan awgTun.Event { return t.events }
func (t *androidAWGTUN) BatchSize() int { return 1 }

func (t *androidAWGTUN) Close() error {
	var err error
	t.closer.Do(func() { close(t.events); err = t.fd.Close() })
	return err
}

func (t *androidAWGTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	n, err := t.fd.Read(bufs[0][offset:])
	if err != nil { return 0, err }
	sizes[0] = n
	return 1, nil
}

func (t *androidAWGTUN) Write(bufs [][]byte, offset int) (int, error) {
	for _, buf := range bufs {
		if _, err := t.fd.Write(buf[offset:]); err != nil { return 0, err }
	}
	return len(bufs), nil
}
