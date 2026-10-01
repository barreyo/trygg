# Trygg diaper button (M5Stack Basic)

Three buttons, one tap each: **A = 💧 PEE**, **B = 💩 POO**, **C = 💧💩 MIXED**.
The screen shows the child's name on top and the emoji above each button. A press
POSTs a `diaper` entry to the [REST API](../docs/api.md) with a family API token;
it shows up live in the app for everyone in the family.

Feedback: the tile goes yellow while sending, green + a short beep when logged, red +
a low beep with the reason (`Bad token`, `Token is read-only`, `Can't reach server`…)
if not. A request that fails in transit is retried with the same `client_id`, so a
lost response can never log the same change twice.

## Local dev setup

The device talks to your Mac over WiFi, so the dev server must listen on the LAN.

```sh
make fw-config          # writes firmware/include/config.h: your LAN IP + a fresh dev token
$EDITOR firmware/include/config.h   # set WIFI_SSID / WIFI_PASSWORD (2.4 GHz only)
make dev-lan            # dev server on 0.0.0.0 (PORT=4012 make dev-lan if 4000 is taken)
make fw-flash           # build + flash over USB-C
make fw-monitor         # optional serial monitor
```

If you change `PORT`, set the same port in `TRYGG_URL`. `firmware/tools/smoke_test.sh`
makes the device's API calls from the Mac (`--read-only` to skip creating entries).

`config.h` holds the WiFi password and token and is gitignored. Tokens come from
`mix trygg.dev_token` locally, or the **Sharing → API access** page (give it "Read and
log" access) for a real server. Point `TRYGG_URL` at an `https://` address and the
certificate is verified against the CA bundle built into the Arduino core.

## Notes

- With several children in the family the first one is used; set `TRYGG_CHILD_ID` to pick.
- The name is refreshed every 10 minutes (renames, a new child).
- The first build downloads the ESP32 toolchain (~1 GB, cached in `~/.platformio`).
  `make` creates the Python venv in `firmware/.venv` on demand.
- Icons are rendered from the macOS emoji font into `src/icons.h` (`make fw-icons`);
  the screen can't draw colour emoji itself.
- Upload speed is 460800 baud; 921600 fails on this board's CP2104.
