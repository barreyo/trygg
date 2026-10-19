# Trygg diaper button (M5Stack Basic)

Three buttons, one tap each: **A = 💧 PEE**, **B = 💩 POO**, **C = 💧💩 MIXED**.
The screen shows the child's name on top and the emoji above each button. A press
POSTs a `diaper` entry to the [REST API](../docs/api.md) with a family API token;
it shows up live in the app for everyone in the family.

Feedback: the moment a button is let go the whole screen turns green for 4 seconds with the
emoji, "PEE logged" and the local time, and plays a little rising chime. Buttons are ignored
while it's up, so a fumbled double tap can't log twice.

## Network: WiFi stays connected

The button is meant to run from USB/mains power, so the radio is always on (no modem sleep) and
the device stays joined to WiFi. A press is *queued* at that moment and delivered in the
background (a sync task on the other CPU core, so the buttons never wait on the network):

1. A press puts `{child, kind, time, client_id}` on a queue and wakes the sync task.
2. The task POSTs the queue oldest first. Presses made while it's running join the same
   run: the task re-checks the queue before it finishes.
3. If the link has dropped, the task first gives the stack's auto-reconnect a few seconds to
   restore it, then joins afresh.

Entries are stamped with when the button was pressed, not when they were delivered. The clock is
set over NTP after the first join and kept in step by the SNTP client. Each press has its
own `client_id`, so a retry after a lost response can never log the same change twice.

If the network or server is out of reach the entries stay queued (up to 20, in RAM) and the
banner reads "N waiting to send"; the retry interval doubles from 5 s up to 1 min, and the
next press retries at once. An entry the server rejects outright (`Bad token`, `Token is
read-only`, `Child not found`…) is dropped and the banner says why, with a low beep. A press
before the first successful connection after boot is refused ("Not connected yet"), since
there's no child to log it for yet.

A power cut or reset loses whatever is still queued.

## Room sensor (ENV Pro)

Plug an [ENV Pro unit](https://docs.m5stack.com/en/unit/Unit_ENV-Pro) (U169, a BME688 at I2C address
`0x77`) into **Port A** (the red HY2.0 connector, GPIO21/22). Nothing needs configuring: the button looks
for it at boot and every minute after that, so it can be plugged in later. Once found it takes a sample
every 30 s (a forced-mode measurement that doesn't block the buttons) and posts it with the same token as
the diaper entries:

```
POST /api/v1/devices/<this board's WiFi MAC>/readings
{"model": "env_pro", "temperature_c": 21.4, "humidity_pct": 46, "pressure_hpa": 1012, "gas_ohms": 91000}
```

The first reading **registers the board as a device** in the family, unnamed. Open the app's menu →
**Devices** (`/c/:id/devices`), where it appears live; give it a name ("Nursery") and every later sample
shows up on that card the moment it arrives (PubSub, no refresh). Registering also hands the board a
random five-digit device id, which the app lists next to the device and the button prints small in the
top right corner of its screen (it is remembered across restarts), so you can tell units apart. Tick
**Show on Today** on the device (or in Today → Customize) to get a live room card on the Today screen.
Samples are kept for 30 days. Only the
latest sample is retried when the network is down; there is no backlog.

`gas_ohms` is the sensor's raw gas resistance (it drops when VOCs rise), shown as a trend, not an air
quality index: the IAQ score needs Bosch's BSEC library, whose licence forbids shipping a compiled
binary, and this firmware is published over the air. The temperature reads a little high if the ENV Pro
sits right against the button; give it some cable.

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

The update check rides on the sync task (see "Network" above): on the first sync after boot,
then at most every 6 hours, the task makes sure WiFi is up and the clock is set (the HTTPS
download needs it), delivers any queued presses, and then asks `GET /api/v1/firmware/button`
(with the token) whether a newer build exists. It only checks when nobody has pressed a button
for a minute. If the server's
`version` is newer than the running build, the task downloads `/api/v1/firmware/button/image` while
the banner shows "Updating NN%" (presses in the meantime are queued as usual), verifies the MD5,
and the device restarts into the new image once the queue is empty and the buttons are idle, since
the queue is lost on a restart. A failed or corrupt download is discarded and the old firmware
keeps running; a failed check is retried after 15 minutes.

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

- The children (names, new child) are re-fetched when they're over an hour old.
- The first build downloads the ESP32 toolchain (~1 GB, cached in `~/.platformio`).
  `make` creates the Python venv in `firmware/.venv` on demand.
- Icons are rendered from the macOS emoji font into `src/icons.h` (`make fw-icons`);
  the screen can't draw colour emoji itself.
- Upload speed is 460800 baud; 921600 fails on this board's CP2104.
