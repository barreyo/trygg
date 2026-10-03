# Trygg diaper button (M5Stack Basic)

Three buttons, one tap each: **A = 💧 PEE**, **B = 💩 POO**, **C = 💧💩 MIXED**.
The screen shows the child's name on top and the emoji above each button. A press
POSTs a `diaper` entry to the [REST API](../docs/api.md) with a family API token;
it shows up live in the app for everyone in the family.

Feedback: the tile goes yellow while sending. When the entry is logged the whole screen
turns green for 4 seconds with the emoji, "PEE logged" and the local time, and plays a
little rising chime. Buttons are ignored while it's up, so a fumbled double tap can't log
twice.
On failure the tile goes red with a low beep and the reason (`Bad token`, `Token is
read-only`, `Can't reach server`…). A request that fails in transit is retried with the
same `client_id`, so a lost response can never log the same change twice.

## Night mode

From 8 PM to 8 AM (local time, per `TIMEZONE`) the screen is dimmed to a low backlight so it
doesn't light up the room, including the green "logged" screen; it comes back at 8 AM. Until the
clock has synced after boot the brightness is left at the daytime level. The hours and levels are
constants at the top of `src/main.cpp`.

## Switching children

A tap logs when the button is let go. Holding a button for about a second does this instead
(and logs nothing):

| Hold          | Does                                                                         |
| ------------- | ---------------------------------------------------------------------------- |
| **A** (left)  | previous child                                                               |
| **C** (right) | next child (both wrap around)                                                |
| **B** (middle)| opens a list: **A** ▲, **C** ▼, **B** selects; closes by itself after 10 s   |

The device remembers its pick across reboots. `TRYGG_CHILD_ID` only decides the starting
child: edit it and re-flash and that wins over the remembered pick.

## Local dev setup

The device talks to your Mac over WiFi, so the dev server must listen on the LAN.

```sh
make fw-config          # writes firmware/include/config.h: LAN IP, timezone + a fresh dev token
$EDITOR firmware/include/config.h   # set WIFI_SSID / WIFI_PASSWORD (2.4 GHz only)
make dev-lan            # dev server on 0.0.0.0 (PORT=4012 make dev-lan if 4000 is taken)
make fw-flash           # build + flash over USB-C (needed once; see "Updating over the air")
make fw-monitor         # optional serial monitor
```

If you change `PORT`, set the same port in `TRYGG_URL`. `firmware/tools/smoke_test.sh`
makes the device's API calls from the Mac (`--read-only` to skip creating entries).

`config.h` holds the WiFi password and token and is gitignored. Tokens come from
`mix trygg.dev_token` locally, or the **Sharing → API access** page (give it "Read and
log" access) for a real server. Point `TRYGG_URL` at an `https://` address and the
certificate is verified against the CA bundle built into the Arduino core.

## Production

Keep one config per environment next to `config.h` (all gitignored) and flash from them:

```sh
cp firmware/include/config.example.h firmware/include/config.h.prod
$EDITOR firmware/include/config.h.prod   # WiFi, TRYGG_URL "https://track.backmanwong.family",
                                         # and a "Read and log" token from Sharing → API access
make fw-flash-prod      # copies config.h.prod over config.h, then flashes
make fw-flash-dev       # same with config.h.dev (see "Local dev setup")
```

The device saves the WiFi, URL and token from the config it was flashed with, so it keeps
working after an over-the-air update (below), which carries none of them.

## Updating over the air

After the first USB flash, new firmware can reach the button without plugging it in:

```sh
make fw-release         # build (without credentials), write priv/firmware/button.{bin,json}
git add priv/firmware && git commit   # then deploy Trygg as usual
```

The button asks `GET /api/v1/firmware/button` (with its token) about 60 s after boot and then
every 6 hours, and only while nobody has pressed anything for a minute. If the server's `version`
is newer than the build it is running, it downloads `/api/v1/firmware/button/image`, shows
"Updating NN%", checks the MD5, and restarts into the new image. A failed or corrupt download is
discarded and the old firmware keeps running; a failed check is retried after 15 minutes.

- Versions are build timestamps (stamped by `make fw-build`/`fw-flash`/`fw-release`). A build you
  flash over USB is newer than the last release, so it isn't overwritten until you release again.
  To roll back, release a build of the old code: that is a new version too.
- The release image has no WiFi password, URL or token in it (they're committed and served);
  the device keeps the ones from its last USB flash. To change them, flash over USB again.
  `TIMEZONE` and `TRYGG_CHILD_ID` still come from `config.h` at release time.
- The very first OTA-capable build has to go over USB (`make fw-flash-prod`): the partition table
  changed to `default_16MB.csv` (two 6.5 MB app slots) for the v2.7 kit's 16 MB of flash.
- There is no automatic rollback of a bad but valid image (a build that can't reach WiFi, say);
  that takes a USB flash. Test a release on the bench before deploying it.
- Use an `https://` `TRYGG_URL` in production: the download is only as trustworthy as the
  connection, since images aren't signed.

## Notes

- The name is refreshed every 10 minutes (renames, a new child).
- The first build downloads the ESP32 toolchain (~1 GB, cached in `~/.platformio`).
  `make` creates the Python venv in `firmware/.venv` on demand.
- Icons are rendered from the macOS emoji font into `src/icons.h` (`make fw-icons`);
  the screen can't draw colour emoji itself.
- Upload speed is 460800 baud; 921600 fails on this board's CP2104.
