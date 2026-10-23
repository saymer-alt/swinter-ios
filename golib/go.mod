module swinter/golib

go 1.25.5

require (
	github.com/amnezia-vpn/amneziawg-go v0.2.16
	github.com/cbeuw/connutil v1.0.1
	github.com/google/uuid v1.6.0
	github.com/metacubex/utls v1.8.4
	github.com/pion/dtls/v3 v3.1.4
	github.com/pion/logging v0.2.4
	github.com/pion/turn/v5 v5.0.2
	github.com/quic-go/quic-go v0.59.0
	github.com/refraction-networking/utls v1.8.3-0.20260301010127-aa6edf4b11af
	github.com/sagernet/sing v0.6.11
	github.com/sagernet/sing-vmess v0.2.7
	github.com/vmihailenco/msgpack/v5 v5.4.1
	golang.org/x/crypto v0.49.0
	golang.org/x/mobile v0.0.0-20250305212854-3a7bc9f8a4de
	golang.zx2c4.com/wireguard v0.0.0-20250521234502-f333402bd9cb
	gvisor.dev/gvisor v0.0.0-20250503011706-39ed1f5ac29c
)

require (
	github.com/andybalholm/brotli v1.1.0 // indirect
	github.com/gofrs/uuid/v5 v5.3.2 // indirect
	github.com/google/btree v1.1.3 // indirect
	github.com/klauspost/compress v1.18.0 // indirect
	github.com/pion/randutil v0.1.0 // indirect
	github.com/pion/stun/v3 v3.1.1 // indirect
	github.com/pion/transport/v4 v4.0.1 // indirect
	github.com/vmihailenco/tagparser/v2 v2.0.0 // indirect
	github.com/wlynxg/anet v0.0.5 // indirect
	golang.org/x/exp v0.0.0-20240904232852-e7e105dedf7e // indirect
	golang.org/x/mod v0.33.0 // indirect
	golang.org/x/net v0.52.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/sys v0.42.0 // indirect
	golang.org/x/time v0.12.0 // indirect
	golang.org/x/tools v0.42.0 // indirect
	golang.zx2c4.com/wintun v0.0.0-20230126152724-0fa3db229ce2 // indirect
)

replace github.com/wlynxg/anet => /tmp/anet-stub
