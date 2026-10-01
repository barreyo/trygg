// Copy to config.h (gitignored) and fill in — `make fw-config` does it for you.
#pragma once

// 2.4 GHz only: the ESP32 can't join a 5 GHz-only network.
#define WIFI_SSID "your-wifi"
#define WIFI_PASSWORD "your-wifi-password"

// Base URL of Trygg, no trailing slash. For local dev use the Mac's LAN
// address and run `make dev-lan`; https:// is verified against the built-in CA bundle.
#define TRYGG_URL "http://192.168.0.10:4000"

// A family API token with "Read and log" access (Sharing page, or locally
// `mix trygg.dev_token`).
#define TRYGG_TOKEN "trygg_..."

// Which child to start on (0 = the first). Long-press the left/right button to
// step through the family's children, the middle one to pick from a list; the
// device remembers the last pick unless you change this and re-flash.
#define TRYGG_CHILD_ID 0

// POSIX timezone for the time shown on the "logged" screen. `make fw-config`
// copies your Mac's; otherwise e.g. "CET-1CEST,M3.5.0,M10.5.0/3" (Stockholm),
// "PST8PDT,M3.2.0,M11.1.0" (Los Angeles) or "UTC0".
#define TIMEZONE "UTC0"
