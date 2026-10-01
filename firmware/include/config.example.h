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

// Which child the buttons log for. 0 = the first child of the family.
#define TRYGG_CHILD_ID 0
