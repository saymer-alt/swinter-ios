//go:build !ios && !android

package vpnlib

import (
	"os"

	"golang.zx2c4.com/wireguard/tun"
	awgTun "github.com/amnezia-vpn/amneziawg-go/tun"
)

type testTUN struct{ fd *os.File }
func (t *testTUN) File() *os.File { return t.fd }
func (t *testTUN) Name() (string, error) { return "test", nil }
func (t *testTUN) MTU() (int, error) { return 1280, nil }
func (t *testTUN) Events() <-chan tun.Event { return make(chan tun.Event) }
func (t *testTUN) BatchSize() int { return 1 }
func (t *testTUN) Close() error { return nil }
func (t *testTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) { select {} }
func (t *testTUN) Write(bufs [][]byte, offset int) (int, error) { return 0, nil }

func createTUN(fd int, mtu int) (tun.Device, error) { return &testTUN{}, nil }

type testAWGTUN struct{}
func (t *testAWGTUN) File() *os.File { return nil }
func (t *testAWGTUN) Name() (string, error) { return "test-awg", nil }
func (t *testAWGTUN) MTU() (int, error) { return 1280, nil }
func (t *testAWGTUN) Events() <-chan awgTun.Event { return make(chan awgTun.Event) }
func (t *testAWGTUN) BatchSize() int { return 1 }
func (t *testAWGTUN) Close() error { return nil }
func (t *testAWGTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) { select {} }
func (t *testAWGTUN) Write(bufs [][]byte, offset int) (int, error) { return 0, nil }

func createAWGTUN(fd int, mtu int) (awgTun.Device, error) { return &testAWGTUN{}, nil }
