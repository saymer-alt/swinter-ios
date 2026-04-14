package vpnlib

// Browser profiles + fingerprint helpers for VK captcha + anon-token flow.
//
// Vendored almost verbatim from:
//   https://github.com/cacggghp/vk-turn-proxy/blob/main/client/profiles.go
//   https://github.com/cacggghp/vk-turn-proxy/blob/main/client/main.go (applyBrowserProfileFhttp, generateBrowserFp)
//
// Original code is MIT-licensed under the Pion community. All credit to
// cacggghp and contributors — we only trimmed the profile list and swapped
// bogdanfinn/fhttp.Request → net/http.Request for gomobile compatibility.

import (
	"crypto/md5"
	"encoding/hex"
	"math/rand"
	"net/http"
)

type vkProfile struct {
	UserAgent       string
	SecChUa         string
	SecChUaMobile   string
	SecChUaPlatform string
}

// Trimmed profile set — upstream ships ~9 profiles across Chrome/Edge on
// Win/Mac/Linux. We keep a handful of recent Chrome profiles. Randomization
// is purely to avoid a static fingerprint; the paired Client Hints must
// agree with the UA string or VK will flag the session.
var vkProfiles = []vkProfile{
	{
		UserAgent:       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
		SecChUa:         `"Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"`,
		SecChUaMobile:   "?0",
		SecChUaPlatform: `"Windows"`,
	},
	{
		UserAgent:       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
		SecChUa:         `"Chromium";v="145", "Not-A.Brand";v="99", "Google Chrome";v="145"`,
		SecChUaMobile:   "?0",
		SecChUaPlatform: `"Windows"`,
	},
	{
		UserAgent:       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
		SecChUa:         `"Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"`,
		SecChUaMobile:   "?0",
		SecChUaPlatform: `"macOS"`,
	},
	{
		UserAgent:       "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
		SecChUa:         `"Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"`,
		SecChUaMobile:   "?0",
		SecChUaPlatform: `"Linux"`,
	},
}

func getRandomVkProfile() vkProfile {
	return vkProfiles[rand.Intn(len(vkProfiles))]
}

func applyBrowserProfile(req *http.Request, p vkProfile) {
	req.Header.Set("User-Agent", p.UserAgent)
	req.Header.Set("sec-ch-ua", p.SecChUa)
	req.Header.Set("sec-ch-ua-mobile", p.SecChUaMobile)
	req.Header.Set("sec-ch-ua-platform", p.SecChUaPlatform)
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("DNT", "1")
}

func generateBrowserFp(p vkProfile) string {
	data := p.UserAgent + p.SecChUa + "1920x1080x24"
	h := md5.Sum([]byte(data))
	return hex.EncodeToString(h[:])
}
