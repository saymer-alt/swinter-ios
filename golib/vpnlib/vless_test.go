package vpnlib

import (
	"context"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"
)

func TestVLESSReality(t *testing.T) {
	config := ServerConfig{
		Protocol: "vless",
		Address:  "mexxx.ru:9443",
		VLESS: &VLESSConf{
			UUID:             "14ac5ba3-519a-4fe8-a48b-992a04b9dfda",
			TLS:              "reality",
			SNI:              "www.google.com",
			Fingerprint:      "chrome",
			RealityPublicKey: "ctK0mS1xFFLoyN06kX90u9vfajiMHCzBn1n48bUr-3Q",
			RealityShortID:   "abcd1234",
			Transport:        "tcp",
		},
	}

	dialer, err := NewVLESSDialer(config)
	if err != nil {
		t.Fatalf("NewVLESSDialer: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	t.Log("Testing VLESS+Reality...")
	conn, err := dialer.DialTCP(ctx, "ip.me:80")
	if err != nil {
		t.Fatalf("DialTCP: %v", err)
	}
	defer conn.Close()

	fmt.Fprint(conn, "GET / HTTP/1.1\r\nHost: ip.me\r\nUser-Agent: curl/8.0\r\nConnection: close\r\n\r\n")

	resp := make([]byte, 4096)
	total := 0
	for {
		n, err := conn.Read(resp[total:])
		total += n
		if err == io.EOF || err != nil { break }
	}

	body := string(resp[:total])
	t.Logf("Response (%d bytes): %.300s", total, body)

	if strings.Contains(body, "HTTP/") {
		t.Log("SUCCESS! Reality works!")
	} else {
		t.Logf("Hex: %x", resp[:min(total, 32)])
		t.Fatal("Reality auth failed — got non-HTTP response")
	}
}

func TestVLESSTLS(t *testing.T) {
	config := ServerConfig{
		Protocol: "vless",
		Address:  "mexxx.ru:443",
		VLESS: &VLESSConf{
			UUID:        "f66c765a-da1a-4913-a6d1-615836308c42",
			TLS:         "tls",
			SNI:         "mexxx.ru",
			Fingerprint: "chrome",
			Flow:        "xtls-rprx-vision",
			Transport:   "tcp",
		},
	}

	dialer, err := NewVLESSDialer(config)
	if err != nil { t.Fatal(err) }

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := dialer.DialTCP(ctx, "ip.me:80")
	if err != nil { t.Fatal(err) }
	defer conn.Close()

	fmt.Fprint(conn, "GET / HTTP/1.1\r\nHost: ip.me\r\nConnection: close\r\n\r\n")

	resp := make([]byte, 4096)
	total := 0
	for { n, err := conn.Read(resp[total:]); total += n; if err != nil { break } }

	t.Logf("Response: %.200s", string(resp[:total]))
	if strings.Contains(string(resp[:total]), "HTTP/") { t.Log("OK!") } else { t.Fatal("FAIL") }
}
