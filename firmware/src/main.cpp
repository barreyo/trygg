// Trygg diaper button for the M5Stack Basic.
//
//   A = PEE   B = POO   C = MIXED   (with the board upright)
//
// Shows the child's name on top and the emoji above each button. SCREEN_ROTATION picks how the board
// is mounted, with each emoji staying over its own button: upside down the buttons are above the
// screen and the order flips, on its side they are a column down one edge.
//
// Meant to run from mains power: WiFi stays connected. A press is acknowledged on the
// spot (green screen + chime) and put on a queue. A background task POSTs the queued
// diaper entries to the Trygg REST API (see docs/api.md) with the family API token from
// config.h, rejoining WiFi first if the link dropped. The UI never waits on the network,
// so presses made mid-sync are queued as well.
//
// An ENV Pro unit (BME688) on Port A is optional: when it answers, the button reports
// temperature, humidity, pressure, gas resistance and Bosch BSEC's air quality (IAQ, CO2 and VOC
// equivalents) to the same API every 30 s, tagged
// with the board's MAC address so the app can list the device and let the family name it.
// The app answers with a five-digit device id, which is kept and printed small in the top right
// corner of the screen, so the family can tell which physical unit is which in the app.
// While the sensor answers, a strip along the top of the screen is coloured by air quality
// (green, yellow, orange, red) with the temperature in its corner.
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <HTTPUpdate.h>
#include <M5Unified.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <esp_timer.h>
#include <time.h>

#include <vector>

#include "bme68x/bme68x.h"
#include "bsec_interface_multi.h"
#include "config.h"

// A release image (`make fw-release`) is published on the server, so it must not carry the
// credentials from config.h. It uses the ones the device saved when it was flashed over USB.
#ifdef FW_RELEASE
#undef WIFI_SSID
#undef WIFI_PASSWORD
#undef TRYGG_URL
#undef TRYGG_TOKEN
#define WIFI_SSID ""
#define WIFI_PASSWORD ""
#define TRYGG_URL ""
#define TRYGG_TOKEN ""
#endif
#include "icons.h"

// Build time as a Unix timestamp, stamped by the Makefile. The server's firmware is
// installed when its version is newer than this, so a build flashed over USB isn't
// replaced by an older release. 0 when built without the Makefile.
#ifndef FW_VERSION
#define FW_VERSION 0
#endif

namespace {

constexpr uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) { return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3); }

const uint16_t COLOR_BG = rgb(16, 20, 24);  // keep in sync with BG in tools/gen_icons.py
const uint16_t COLOR_TEXT = rgb(255, 255, 255);
const uint16_t COLOR_DIM = rgb(140, 148, 156);
const uint16_t COLOR_IDLE = rgb(48, 56, 64);
const uint16_t COLOR_BUSY = rgb(240, 180, 40);
const uint16_t COLOR_OK = rgb(60, 200, 110);
const uint16_t COLOR_OK_BG = rgb(34, 160, 80);  // keep in sync with OK_BG in tools/gen_icons.py
const uint16_t COLOR_ERR = rgb(230, 70, 70);

struct Action {
  const char* kind;  // API value of data.kind
  const char* label;
  const uint16_t* icon;
  const uint16_t* icon_big;  // on the green "logged" screen
  int along;  // where its button is, measured along the row of buttons (the screen's long side)
};

// In reading order: left to right with the buttons below the screen (or above it, held upside down),
// top to bottom with the board on its side. Which physical button that is depends on how it's held.
const Action ACTIONS[3] = {
    {"pee", "PEE", ICON_PEE, ICON_PEE_BIG, 66},
    {"poo", "POO", ICON_POO, ICON_POO_BIG, 160},
    {"mixed", "MIXED", ICON_MIXED, ICON_MIXED_BIG, 254},
};

const int TILE_W = 84;
const int TILE_H = 120;
const int TILE_PORTRAIT_W = 130;  // on its side the tiles are wide and short, in a column on the buttons' side
const int TILE_PORTRAIT_H = 84;
const int TILE_MARGIN = 4;
const int BAR_H = 18;   // the climate bar along the edge farthest from the buttons
const int COLUMN_W = 96;  // what's left beside the tiles for the name and banner

const unsigned long CHILD_REFRESH_MS = 60UL * 60UL * 1000UL;  // names are re-fetched when they're older
const unsigned long BANNER_MS = 4000;
const unsigned long LOGGED_SCREEN_MS = 4000;
const int HTTP_TIMEOUT_MS = 8000;
const int MAX_ATTEMPTS = 3;  // per entry, per sync, before backing off
const size_t QUEUE_MAX = 20;
const unsigned long WIFI_RECONNECT_MS = 5000;  // a dropped link gets this long to come back by itself
const unsigned long WIFI_JOIN_MS = 15000;      // then a fresh join
const unsigned long CLOCK_WAIT_MS = 10000;     // first NTP sync after boot
const unsigned long RETRY_BASE_MS = 5000;      // after a failed sync, doubling...
const unsigned long RETRY_MAX_MS = 60UL * 1000UL;  // ...up to this
const unsigned long HOLD_MS = 800;           // long press: left/right switch child, middle lists them
const unsigned long LIST_TIMEOUT_MS = 10000;  // the picker closes itself after this much quiet
const int LIST_ROWS = 5;

// ENV Pro (BME688) on Port A, read through M5Unified's I2C (shared with the board's own bus).
// Bosch's BSEC library runs the sensor: it asks for a measurement every 3 s (low-power mode) and turns
// the raw readings into compensated temperature/humidity and an air quality index. A sample is posted
// to the app every SENSOR_PERIOD_MS, from whatever BSEC has worked out by then.
const uint8_t SENSOR_ADDR = BME68X_I2C_ADDR_HIGH;  // 0x77
const uint32_t SENSOR_I2C_HZ = 400000;
const unsigned long SENSOR_PERIOD_MS = 30UL * 1000UL;  // one sample posted this often
const unsigned long SENSOR_RETRY_MS = 60UL * 1000UL;   // looking for a sensor that isn't there (yet)
const int SENSOR_MAX_FAILS = 3;                        // bad reads in a row before searching again
const float SENSOR_TEMP_OFFSET_C = 1.3255f;            // the board's own heat in the reading; Bosch's
                                                       // low-power value, tune against a thermometer
const unsigned long BSEC_SAVE_MS = 6UL * 60UL * 60UL * 1000UL;  // keep what BSEC has learned this fresh

// Over-the-air updates: look for a newer release this often, but only once the device has
// been left alone for a while (an update takes a few seconds and ignores the buttons).
const unsigned long UPDATE_CHECK_MS = 6UL * 60UL * 60UL * 1000UL;
const unsigned long UPDATE_RETRY_MS = 15UL * 60UL * 1000UL;
const unsigned long UPDATE_QUIET_MS = 60UL * 1000UL;

// How the board is mounted, as seen by whoever is reading it: 0 = buttons below the screen, 1 = buttons
// on the right, 2 = above, 3 = on the left. The Basic has no accelerometer, so this is fixed at build
// time. M5GFX counts from the panel's own landscape, which is its rotation 1.
const int SCREEN_ROTATION = 0;

// Screen brightness (0-255): dim at night so it doesn't light up the nursery.
const int DAY_BRIGHTNESS = 90;
const int NIGHT_BRIGHTNESS = 10;
const int NIGHT_START_HOUR = 20;  // 8 PM local time...
const int NIGHT_END_HOUR = 8;     // ...until 8 AM
const unsigned long BRIGHTNESS_CHECK_MS = 30000;

struct Child {
  long id;
  String name;
};

std::vector<Child> children;  // everything the token can see, as of the last load (UI task only)
int current = -1;             // index into `children`
String child_name;
long child_id = 0;
unsigned long banner_until = 0;
String shown_banner;             // what the banner area currently says ("" = unknown, redraw)
unsigned long logged_until = 0;  // full-screen "logged" view is up until then
String last_logged;              // e.g. "PEE 14:32", shown once the full-screen view is gone

// A press waiting to be delivered. `client_id` is minted at press time, so every
// retry is idempotent on the server.
struct Pending {
  uint8_t action;  // index into ACTIONS
  long child_id;
  time_t pressed_at;           // 0 if the clock hadn't synced yet...
  unsigned long pressed_ms;    // ...then the time is worked out from this when sending
  char client_id[37];
};

// Shared by the UI (Arduino loop) task and the sync task. The mutex guards `queue`,
// `fetched` and `sync_error`; the volatile words are fine to read without it. The
// sync task never draws, and the UI never waits on the network.
SemaphoreHandle_t mu;
TaskHandle_t sync_task;
std::vector<Pending> queue;     // only the UI appends, only the sync task removes
std::vector<Child> fetched;     // children fetched by the sync task, waiting for the UI to adopt
char sync_error[40];            // latest failure the user should hear about
volatile int pending_count = 0;
volatile bool fetched_ready = false;
volatile uint32_t error_seq = 0;
volatile bool syncing = false;
volatile bool have_children = false;
volatile unsigned long child_loaded_at = 0;
volatile unsigned long last_fail_at = 0;
volatile unsigned long retry_delay = 0;  // 0: due right away

// The latest sensor sample, waiting to be sent. Written by the UI task (guarded by `mu`), taken by the
// sync task. A newer sample replaces an unsent one: only the current state is worth reporting.
struct Sample {
  float temperature_c, humidity_pct, pressure_hpa, gas_ohms;
  float iaq, co2_ppm, voc_ppm;  // BSEC's static IAQ (0 clean .. 500 bad), CO2 and breath-VOC equivalents
  uint8_t iaq_accuracy;         // 0 still learning .. 3 calibrated
  bool has_gas, has_iaq;
  time_t at;  // 0 if the clock hadn't synced; the server then stamps it on arrival
};
Sample sample;
volatile bool sample_ready = false;
String device_id;  // this board's WiFi MAC address, how the app tells devices apart
// The five-digit id the app gave this device when it registered (0: not registered yet). Remembered
// across restarts; the sync task sets it, the UI redraws when `short_id_dirty`.
volatile long short_id = 0;
volatile bool short_id_dirty = false;

// What the climate bar along the top of the screen shows (UI task only). `show` is true while the
// sensor is online and has produced a temperature; `air` is 0 while BSEC is still calibrating (or has
// no index), else 1 green .. 4 red by how good the air is.
struct {
  bool show = false;
  float temperature_c = 0;
  int air = 0;
} climate;

// Over-the-air updates. The sync task checks for a release and installs it; the UI shows
// the progress and does the restart, once nothing is waiting in the (RAM-only) queue.
volatile int update_pct = -1;                  // download progress, -1 when not downloading
volatile bool restart_pending = false;         // a new image is installed, running the old one until restart
volatile unsigned long last_activity = 0;      // last button press; updates only start on a quiet device
volatile unsigned long last_update_check = 0;  // 0: not checked since boot
volatile unsigned long update_interval = 0;    // how long after that check the next one is due

// Where to connect and who as. Compiled in from config.h on a USB flash, which also saves
// them to the device; an over-the-air image carries none and reads the saved ones.
struct {
  String ssid, password, url, token;
} net;

// Buttons whose current press must not log: it was a long press, or started while
// a full-screen view ignored the buttons. Cleared by the next press, so a button
// held through a dismissal can't log when it's finally let go.
bool consumed[3] = {false, false, false};

bool list_open = false;
int list_sel = 0;
unsigned long list_until = 0;

m5::Button_Class& btn(int i) { return i == 0 ? M5.BtnA : (i == 1 ? M5.BtnB : M5.BtnC); }

// ---- layout ----------------------------------------------------------------

struct Rect {
  int x, y, w, h;
};

// Everything that depends on how the board is held. The buttons are always on the edge of the screen
// that is nearest them, so the tiles hug that edge, each over its own button, and the name and banner
// take the rest.
struct Layout {
  int rotation;
  bool portrait;  // on its side: 240x320, the buttons in a column
  bool flipped;   // reading order runs against the A, B, C order of the buttons
  Rect name, banner;
  Rect bar;                    // the climate bar: the screen's edge farthest from the buttons
  Rect tile[3];                // by action
  int id_x, id_y;              // the device id, in the corner farthest from the buttons
  lgfx::textdatum_t id_datum;
};

Layout layoutFor(int rotation) {
  Layout l;
  l.rotation = rotation;
  l.portrait = rotation & 1;
  l.flipped = rotation == 1 || rotation == 2;
  if (!l.portrait) {
    const int w = 320, h = 240;
    bool buttons_above = rotation == 2;
    l.name = {0, buttons_above ? h - 56 : 0, w, 56};
    l.banner = {0, buttons_above ? h - 104 : 60, w, 44};
    l.bar = {0, buttons_above ? h - BAR_H : 0, w, BAR_H};
    l.id_x = w - 3;
    l.id_y = buttons_above ? h - 3 : 3;
    l.id_datum = buttons_above ? bottom_right : top_right;
    for (int i = 0; i < 3; i++) l.tile[i] = {ACTIONS[i].along - TILE_W / 2, buttons_above ? 8 : h - 8 - TILE_H, TILE_W, TILE_H};
  } else {
    const int w = 240;
    bool buttons_right = rotation == 1;
    int tile_x = buttons_right ? w - TILE_MARGIN - TILE_PORTRAIT_W : TILE_MARGIN;
    int col_x = buttons_right ? TILE_MARGIN : tile_x + TILE_PORTRAIT_W + 6;
    l.name = {col_x, 14, COLUMN_W, 100};
    l.banner = {col_x, 118, COLUMN_W, 150};
    l.bar = {0, 0, w, BAR_H};  // across the top, clear of the tiles (which start at y = 24)
    l.id_x = col_x + COLUMN_W;
    l.id_y = 3;
    l.id_datum = top_right;
    for (int i = 0; i < 3; i++) l.tile[i] = {tile_x, ACTIONS[i].along - TILE_PORTRAIT_H / 2, TILE_PORTRAIT_W, TILE_PORTRAIT_H};
  }
  return l;
}

Layout lay = layoutFor(0);

// The action under a physical button (0 = A .. 2 = C) with the board held as it is now, and back.
// Held with the buttons on the right or above, A is the last one in reading order, so it mixes.
int actionFor(int button) { return lay.flipped ? 2 - button : button; }

// ---- drawing ---------------------------------------------------------------

// Word-wraps `text` into lines no wider than `width` in the current font. False if a single word is
// wider than that on its own.
bool wrapText(const String& text, int width, std::vector<String>& lines) {
  lines.clear();
  String line;
  int pos = 0, n = text.length();
  while (pos < n) {
    int sp = text.indexOf(' ', pos);
    String word = sp < 0 ? text.substring(pos) : text.substring(pos, sp);
    pos = sp < 0 ? n : sp + 1;
    if (!word.length()) continue;
    String joined = line.length() ? line + " " + word : word;
    if (line.length() && M5.Display.textWidth(joined) > width) {
      lines.push_back(line);
      line = word;
    } else {
      line = joined;
    }
  }
  if (line.length() || lines.empty()) lines.push_back(line);
  for (auto& l : lines) {
    if (M5.Display.textWidth(l) > width) return false;
  }
  return true;
}

// Draws `text` centred in `r` (minus `pad` on each side), in the first of `fonts` that fits on at most
// `max_lines` lines. If none does it's one line in the last font, clipped to `r`.
void drawFitted(const String& text, const Rect& r, int pad, const lgfx::IFont* const* fonts, int n_fonts, int max_lines,
                uint16_t color) {
  auto& d = M5.Display;
  std::vector<String> lines;
  bool fits = false;
  for (int f = 0; f < n_fonts && !fits; f++) {
    d.setFont(fonts[f]);
    fits = wrapText(text, r.w - 2 * pad, lines) && (int)lines.size() <= max_lines;
  }
  if (!fits) lines.assign(1, text);
  int fh = d.fontHeight();
  int y = r.y + (r.h - fh * (int)lines.size()) / 2 + fh / 2;
  d.setClipRect(r.x, r.y, r.w, r.h);
  d.setTextColor(color, COLOR_BG);
  d.setTextDatum(middle_center);
  for (auto& l : lines) {
    d.drawString(l, r.x + r.w / 2, y);
    y += fh;
  }
  d.clearClipRect();
}

// The bar's colours by air quality: fixed green/yellow/orange/red, a neutral grey while the index is
// still being learned. {background, text}
void climateColors(int air, uint16_t& bg, uint16_t& fg) {
  switch (air) {
    case 1: bg = rgb(60, 200, 110); fg = rgb(8, 40, 20); break;
    case 2: bg = rgb(240, 214, 60); fg = rgb(50, 40, 0); break;
    case 3: bg = rgb(240, 150, 50); fg = rgb(50, 24, 0); break;
    case 4: bg = rgb(220, 60, 60); fg = rgb(255, 255, 255); break;
    default: bg = COLOR_IDLE; fg = COLOR_TEXT; break;
  }
}

// The name's area: `lay.name`, less the climate bar's share of it while the bar is up.
Rect nameRect() {
  Rect r = lay.name;
  if (!climate.show) return r;
  if (lay.bar.y == 0) {
    int top = max(r.y, BAR_H);
    r.h -= top - r.y;
    r.y = top;
  } else {
    r.h = min(r.h, lay.bar.y - r.y);
  }
  return r;
}

// The device id, tiny, in the corner away from the buttons, or on the climate bar when that is up.
// Nothing until the app has handed one out.
void drawShortId() {
  if (!short_id) return;
  auto& d = M5.Display;
  uint16_t bg = COLOR_BG, fg = COLOR_DIM;
  char buf[8];
  snprintf(buf, sizeof buf, "%05ld", (long)short_id);
  d.setFont(&fonts::Font0);  // 6x8 px
  if (climate.show) {
    climateColors(climate.air, bg, fg);
    d.setTextColor(fg, bg);
    d.setTextDatum(middle_right);
    d.drawString(buf, lay.bar.x + lay.bar.w - 4, lay.bar.y + BAR_H / 2);
    return;
  }
  d.setTextColor(fg, bg);
  d.setTextDatum(lay.id_datum);
  d.drawString(buf, lay.id_x, lay.id_y);
}

// The strip along the screen's far edge while a room sensor is online: coloured by air quality, the
// temperature in its left corner. The sensor is on this board, so "online" is whether it is answering.
void drawClimateBar() {
  if (!climate.show) return;
  auto& d = M5.Display;
  uint16_t bg, fg;
  climateColors(climate.air, bg, fg);
  d.fillRect(lay.bar.x, lay.bar.y, lay.bar.w, lay.bar.h, bg);
  char buf[12];
  snprintf(buf, sizeof buf, "%.1f°C", climate.temperature_c);
  d.setFont(&fonts::lgfxJapanGothic_16);
  d.setTextColor(fg, bg);
  d.setTextDatum(middle_left);
  d.drawString(buf, lay.bar.x + 6, lay.bar.y + BAR_H / 2);
  drawShortId();
}

void drawName() {
  auto& d = M5.Display;
  d.fillRect(lay.bar.x, lay.bar.y, lay.bar.w, lay.bar.h, COLOR_BG);  // the bar, if it was up
  d.fillRect(lay.name.x, lay.name.y, lay.name.w, lay.name.h, COLOR_BG);
  static const lgfx::IFont* const wide[] = {&fonts::lgfxJapanGothic_32, &fonts::lgfxJapanGothic_24, &fonts::lgfxJapanGothic_16};
  static const lgfx::IFont* const narrow[] = {&fonts::lgfxJapanGothic_24, &fonts::lgfxJapanGothic_20, &fonts::lgfxJapanGothic_16};
  String text = child_name.length() ? child_name : String("Trygg");
  Rect r = nameRect();
  if (lay.portrait) drawFitted(text, r, 0, narrow, 3, 2, COLOR_TEXT);
  else drawFitted(text, r, 8, wide, 3, 1, COLOR_TEXT);
  if (climate.show) drawClimateBar();
  else drawShortId();
}

// Brings the climate bar up to date: appears, disappears or recolours as the sensor's state changes.
void updateClimateBar() {
  static bool shown = false;
  static int shown_air = -1;
  static int shown_tenths = 0;
  int tenths = (int)lroundf(climate.temperature_c * 10);
  if (climate.show != shown) {
    shown = climate.show;
    shown_air = climate.air;
    shown_tenths = tenths;
    drawName();  // the name gives up room to the bar, so it is redrawn with it
  } else if (shown && (climate.air != shown_air || tenths != shown_tenths)) {
    shown_air = climate.air;
    shown_tenths = tenths;
    drawClimateBar();
  }
}

// One line under the name: what just happened, or the connection state. A few short lines when the
// board is on its side and there is little room.
void drawBanner(const String& text, uint16_t color) {
  shown_banner = text;
  auto& d = M5.Display;
  d.fillRect(lay.banner.x, lay.banner.y, lay.banner.w, lay.banner.h, COLOR_BG);
  static const lgfx::IFont* const sizes[] = {&fonts::lgfxJapanGothic_20, &fonts::lgfxJapanGothic_16};
  drawFitted(text, lay.banner, lay.portrait ? 0 : 4, sizes, 2, lay.portrait ? 5 : 1, color);
}

void drawTile(int i, uint16_t border) {
  auto& d = M5.Display;
  const Action& a = ACTIONS[i];
  const Rect& t = lay.tile[i];
  d.fillRoundRect(t.x, t.y, t.w, t.h, 10, COLOR_BG);
  d.drawRoundRect(t.x, t.y, t.w, t.h, 10, border);
  d.drawRoundRect(t.x + 1, t.y + 1, t.w - 2, t.h - 2, 9, border);
  d.setTextColor(COLOR_TEXT, COLOR_BG);
  d.setTextDatum(middle_center);
  if (lay.portrait) {
    d.pushImage(t.x + 8, t.y + (t.h - ICON_SIZE) / 2, ICON_SIZE, ICON_SIZE, a.icon);
    d.setFont(&fonts::lgfxJapanGothic_16);
    d.drawString(a.label, t.x + 8 + ICON_SIZE + (t.w - 8 - ICON_SIZE) / 2, t.y + t.h / 2);
  } else {
    d.pushImage(t.x + (t.w - ICON_SIZE) / 2, t.y + 10, ICON_SIZE, ICON_SIZE, a.icon);
    d.setFont(&fonts::lgfxJapanGothic_20);
    d.drawString(a.label, t.x + t.w / 2, t.y + 96);
  }
}

void drawAll() {
  M5.Display.fillScreen(COLOR_BG);
  shown_banner = "";  // wiped with the screen, so any timed message is gone too
  banner_until = 0;
  drawName();
  for (int i = 0; i < 3; i++) drawTile(i, COLOR_IDLE);
}

void setTiles(uint16_t color, int only = -1) {
  for (int i = 0; i < 3; i++) drawTile(i, (only < 0 || only == i) ? color : COLOR_IDLE);
}

bool clockSynced() { return time(nullptr) > 1700000000; }

// Local wall-clock time as HH:MM, or "" if the clock isn't synced yet.
String localTime() {
  if (!clockSynced()) return "";
  time_t now = time(nullptr);
  struct tm tm;
  localtime_r(&now, &tm);
  char buf[6];
  strftime(buf, sizeof buf, "%H:%M", &tm);
  return String(buf);
}

// Takes over the whole screen, all green, once an entry is logged.
void drawLogged(const Action& a, const String& time) {
  auto& d = M5.Display;
  // Centred on the screen, so the same whichever way up it is held; on its side there's more height.
  int icon_y = lay.portrait ? 36 : 14, label_y = lay.portrait ? 170 : 140, time_y = lay.portrait ? 250 : 196;
  d.fillScreen(COLOR_OK_BG);
  d.pushImage(d.width() / 2 - ICON_BIG_SIZE / 2, icon_y, ICON_BIG_SIZE, ICON_BIG_SIZE, a.icon_big);
  d.setTextColor(COLOR_TEXT, COLOR_OK_BG);
  d.setTextDatum(middle_center);
  String label = String(a.label) + " logged";
  d.setFont(&fonts::lgfxJapanGothic_32);
  if (d.textWidth(label) > d.width() - 8) d.setFont(&fonts::lgfxJapanGothic_24);
  d.drawString(label, d.width() / 2, label_y);
  if (time.length()) {
    d.setFont(&fonts::Font7);  // big 7-segment digits
    d.drawString(time, d.width() / 2, time_y);
  }
}

// Fits `text` into `width` pixels by stepping down through the font sizes.
void fitFont(const String& text, int width) {
  const lgfx::IFont* fonts[] = {&fonts::lgfxJapanGothic_24, &fonts::lgfxJapanGothic_20, &fonts::lgfxJapanGothic_16};
  for (auto font : fonts) {
    M5.Display.setFont(font);
    if (M5.Display.textWidth(text) <= width) break;
  }
}

// The child picker: ▲ / OK / ▼ beside the three buttons, each over its own button.
void drawList() {
  auto& d = M5.Display;
  int n = children.size();
  // Rows fill the screen minus the strip the arrows sit in, which is on the buttons' side.
  int row_x = lay.portrait ? (lay.rotation == 1 ? 10 : 56) : 12;
  int row_w = lay.portrait ? d.width() - 66 : d.width() - 24;
  int arrow_c = lay.portrait ? (lay.rotation == 1 ? d.width() - 28 : 28) : (lay.rotation == 2 ? 18 : 222);
  int title_y = lay.rotation == 2 ? 224 : 16;
  d.fillScreen(COLOR_BG);
  d.setTextColor(COLOR_DIM, COLOR_BG);
  d.setTextDatum(middle_center);
  d.setFont(&fonts::lgfxJapanGothic_20);
  d.drawString("Choose child", row_x + row_w / 2, title_y);

  int top = max(0, min(list_sel - LIST_ROWS / 2, n - LIST_ROWS));
  for (int r = 0; r < LIST_ROWS && top + r < n; r++) {
    int idx = top + r;
    int y = 34 + r * 34;
    bool sel = idx == list_sel;
    if (sel) {
      d.fillRoundRect(row_x, y, row_w, 32, 8, COLOR_IDLE);
      d.drawRoundRect(row_x, y, row_w, 32, 8, COLOR_BUSY);
    }
    d.setTextColor(sel ? COLOR_TEXT : COLOR_DIM, sel ? COLOR_IDLE : COLOR_BG);
    d.setTextDatum(middle_left);
    fitFont(children[idx].name, row_w - 56);
    d.drawString(children[idx].name, row_x + 16, y + 16);
    if (idx == current) d.fillCircle(row_x + row_w - 18, y + 16, 5, COLOR_OK);
  }

  // Reading order: the first action's button is ▲, the last one's ▼, the middle one's OK.
  int ax[3], ay[3];
  for (int i = 0; i < 3; i++) {
    ax[i] = lay.portrait ? arrow_c : ACTIONS[i].along;
    ay[i] = lay.portrait ? ACTIONS[i].along : arrow_c;
  }
  d.fillTriangle(ax[0], ay[0] - 8, ax[0] - 10, ay[0] + 8, ax[0] + 10, ay[0] + 8, COLOR_TEXT);
  d.fillTriangle(ax[2], ay[2] + 8, ax[2] - 10, ay[2] - 8, ax[2] + 10, ay[2] - 8, COLOR_TEXT);
  d.setTextColor(COLOR_TEXT, COLOR_BG);
  d.setTextDatum(middle_center);
  d.setFont(&fonts::lgfxJapanGothic_20);
  d.drawString("OK", ax[1], ay[1]);
}

void showBanner(const String& text, uint16_t color, unsigned long ms = 0) {
  drawBanner(text, color);
  banner_until = ms ? millis() + ms : 0;
}

// The resting banner: sync progress while entries are waiting, else the last entry
// (or the connection state before the first child list has arrived). Redrawn only
// when it changes, and never over a timed message.
void updateIdleBanner() {
  if (banner_until) return;
  String text;
  uint16_t color = COLOR_DIM;
  int waiting = pending_count;
  if (update_pct >= 0) {
    text = "Updating " + String(update_pct) + "%";
    color = COLOR_BUSY;
  } else if (waiting) {
    text = syncing ? "Sending " + String(waiting) + "…" : String(waiting) + " waiting to send";
    color = COLOR_BUSY;
  } else if (!child_name.length()) {
    text = syncing ? "Connecting…" : "Not connected";
    color = syncing ? COLOR_BUSY : COLOR_DIM;
  } else {
    text = last_logged.length() ? "Last: " + last_logged : String("Ready");
  }
  if (text != shown_banner) drawBanner(text, color);
}

void beep(int hz, int ms) { M5.Speaker.tone(hz, ms); }

// A little rising "ta-da-da-DING" (C6 E6 G6 C7). Blocks for about half a second,
// which is fine: the "logged" screen ignores the buttons anyway.
void successChime() {
  const struct {
    int hz;
    int ms;
  } notes[] = {{1047, 70}, {1319, 70}, {1568, 70}, {2093, 220}};
  for (auto n : notes) {
    M5.Speaker.tone(n.hz, n.ms);
    delay(n.ms + 25);
  }
}

// Dims the screen from NIGHT_START_HOUR until NIGHT_END_HOUR (local time). Until
// the clock has synced the hour is unknown, so the brightness is left as it is.
void updateBrightness() {
  if (!clockSynced()) return;
  time_t now = time(nullptr);
  struct tm tm;
  localtime_r(&now, &tm);
  bool night = tm.tm_hour >= NIGHT_START_HOUR || tm.tm_hour < NIGHT_END_HOUR;
  static int applied = -1;
  int target = night ? NIGHT_BRIGHTNESS : DAY_BRIGHTNESS;
  if (target != applied) {
    M5.Display.setBrightness(target);
    applied = target;
  }
}

// ---- network ---------------------------------------------------------------

void loadNetSettings() {
  Preferences prefs;
  prefs.begin("trygg", false);
  if (strlen(WIFI_SSID) && strlen(TRYGG_URL) && strlen(TRYGG_TOKEN)) {
    prefs.putString("ssid", WIFI_SSID);
    prefs.putString("pass", WIFI_PASSWORD);
    prefs.putString("url", TRYGG_URL);
    prefs.putString("token", TRYGG_TOKEN);
  }
  net.ssid = prefs.getString("ssid", "");
  net.password = prefs.getString("pass", "");
  net.url = prefs.getString("url", "");
  net.token = prefs.getString("token", "");
  short_id = prefs.getLong("sid", 0);
  prefs.end();
}

// The app's answer to a reading names the device; remember it if it is new.
void adoptShortId(const String& body) {
  JsonDocument doc;
  if (deserializeJson(doc, body)) return;
  long id = doc["data"]["short_id"].as<long>();
  if (id < 10000 || id > 99999 || id == short_id) return;
  Preferences prefs;
  prefs.begin("trygg", false);
  prefs.putLong("sid", id);
  prefs.end();
  short_id = id;
  short_id_dirty = true;
}

// From here to `syncTask` the code runs on the sync task and must not touch the
// display or UI state; it talks to the UI through the shared state at the top.

struct Lock {
  Lock() { xSemaphoreTake(mu, portMAX_DELAY); }
  ~Lock() { xSemaphoreGive(mu); }
};

void postError(const char* msg);

bool waitJoined(unsigned long ms) {
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < ms) vTaskDelay(pdMS_TO_TICKS(100));
  return WiFi.status() == WL_CONNECTED;
}

// Makes sure WiFi is joined and the clock is set (entries are stamped with it, and TLS
// needs it). The radio is never switched off: normally this returns at once. If the link
// dropped, the stack's auto-reconnect gets a moment to restore it before a fresh join.
bool wifiUp() {
  static bool begun = false;
  static bool sntp_started = false;

  if (!net.ssid.length()) {
    static bool reported = false;
    if (!reported) postError("Not configured: flash with config.h");
    reported = true;
    return false;
  }
  bool joined = WiFi.status() == WL_CONNECTED || (begun && waitJoined(WIFI_RECONNECT_MS));
  if (!joined) {
    WiFi.disconnect();
    WiFi.begin(net.ssid.c_str(), net.password.c_str());
    WiFi.setAutoReconnect(true);
    begun = true;
    joined = waitJoined(WIFI_JOIN_MS);
  }
  if (!joined) return false;

  // The SNTP client keeps the clock in step by itself from here on; it only needs starting
  // once. configTime() would reset TZ to UTC, so the timezone goes in with the servers.
  if (!sntp_started) {
    configTzTime(TIMEZONE, "pool.ntp.org", "time.google.com");
    sntp_started = true;
  }
  unsigned long start = millis();
  while (!clockSynced() && millis() - start < CLOCK_WAIT_MS) vTaskDelay(pdMS_TO_TICKS(100));
  return clockSynced();
}

void postError(const char* msg) {
  Lock lock;
  strlcpy(sync_error, msg, sizeof sync_error);
  error_seq = error_seq + 1;
}

String isoAt(time_t t) {
  struct tm tm;
  gmtime_r(&t, &tm);
  char buf[25];
  strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", &tm);
  return String(buf);
}

void uuid4(char (&out)[37]) {
  uint8_t b[16];
  esp_fill_random(b, sizeof b);
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  snprintf(out, sizeof out, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", b[0], b[1], b[2],
           b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
}

// Verify the server against the CA bundle built into the Arduino core. Needs a synced
// clock for the certificate dates.
void trustBundle(WiFiClientSecure& client) {
  extern const uint8_t rootca_crt_bundle_start[] asm("_binary_x509_crt_bundle_start");
  client.setCACertBundle(rootca_crt_bundle_start);
}

// Sends one request and returns the HTTP status (negative on transport errors).
// `out` receives the response body.
int request(const char* method, const String& path, const String& body, String& out) {
  String url = net.url + path;
  bool tls = url.startsWith("https://");
  WiFiClient plain;
  WiFiClientSecure secure;
  if (tls) trustBundle(secure);
  HTTPClient http;
  http.setConnectTimeout(HTTP_TIMEOUT_MS);
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!(tls ? http.begin(secure, url) : http.begin(plain, url))) return -1;
  http.addHeader("Authorization", "Bearer " + net.token);
  http.addHeader("Accept", "application/json");
  if (body.length()) http.addHeader("Content-Type", "application/json");
  int status = http.sendRequest(method, body);
  if (status > 0) out = http.getString();
  http.end();
  return status;
}

String describeFailure(int status) {
  switch (status) {
    case 401: return "Bad token (401)";
    case 403: return "Token is read-only";
    case 404: return "Child not found";
    case 422: return "Rejected (422)";
    default: return status < 0 ? String("Can't reach server") : "Server error " + String(status);
  }
}

void selectChild(int idx) {
  current = idx;
  child_id = children[idx].id;
  child_name = children[idx].name;
}

// The child to start on: the one last picked on the device, unless TRYGG_CHILD_ID
// was changed since (editing the config and re-flashing wins), else the config's.
long preferredChildId() {
  Preferences prefs;
  prefs.begin("trygg", true);
  long configured = prefs.getLong("cfg", -1);
  long saved = prefs.getLong("child", 0);
  prefs.end();
  return (configured == TRYGG_CHILD_ID && saved) ? saved : TRYGG_CHILD_ID;
}

void saveChoice() {
  Preferences prefs;
  prefs.begin("trygg", false);
  prefs.putLong("cfg", TRYGG_CHILD_ID);
  prefs.putLong("child", child_id);
  prefs.end();
}

// A 4xx won't get better by retrying (408 and 429 will).
bool permanent(int status) { return status >= 400 && status < 500 && status != 408 && status != 429; }

// Sync task: fetches the family's children and hands them to the UI (adoptChildren).
// Only failures worth telling the user about are reported; a flaky network just
// means trying again later.
bool fetchChildren() {
  String body;
  int status = request("GET", "/api/v1/children", "", body);
  if (status != 200) {
    if (permanent(status)) postError(describeFailure(status).c_str());
    return false;
  }
  JsonDocument doc;
  if (deserializeJson(doc, body)) {
    postError("Bad response");
    return false;
  }
  std::vector<Child> loaded;
  bool read_only = false;
  for (JsonVariant c : doc["data"].as<JsonArray>()) {
    loaded.push_back({c["id"].as<long>(), c["name"].as<String>()});
    read_only = read_only || c["role"] == "viewer";
  }
  if (loaded.empty()) {
    postError("No children yet");
    return false;
  }
  if (read_only) {
    postError("Token is read-only");
    return false;
  }
  Lock lock;
  fetched = loaded;
  fetched_ready = true;
  return true;
}

// UI task: takes over a freshly fetched children list. Keeps the current child
// across refreshes; the first time, picks the remembered one (see preferredChildId),
// else the first.
void adoptChildren() {
  std::vector<Child> loaded;
  {
    Lock lock;
    if (!fetched_ready) return;
    loaded.swap(fetched);
    fetched_ready = false;
  }
  long want = child_id ? child_id : preferredChildId();
  children = loaded;
  int idx = 0;
  for (int i = 0; i < (int)children.size(); i++) {
    if (children[i].id == want) idx = i;
  }
  selectChild(idx);
  child_loaded_at = millis();
  have_children = true;
  drawName();
}

// Long press left (-1) / right (+1): previous / next child, wrapping round.
void cycleChild(int dir) {
  int n = children.size();
  if (n < 2) {
    showBanner(n ? "Only one child" : "Not connected yet", COLOR_DIM, BANNER_MS);
    beep(300, 120);
    return;
  }
  selectChild((current + dir + n) % n);
  saveChoice();
  drawName();
  showBanner("Child " + String(current + 1) + " of " + String(n), COLOR_TEXT, BANNER_MS);
  beep(dir < 0 ? 900 : 1400, 70);
}

// Long press middle: pick from a list. ▲ ▼ move, OK selects, or wait to cancel.
void openList() {
  if (children.empty()) {
    showBanner("Not connected yet", COLOR_DIM, BANNER_MS);
    beep(300, 120);
    return;
  }
  list_open = true;
  list_sel = current;
  list_until = millis() + LIST_TIMEOUT_MS;
  drawList();
  beep(1100, 70);
}

void closeList(bool apply) {
  list_open = false;
  bool changed = apply && list_sel != current;
  if (changed) {
    selectChild(list_sel);
    saveChoice();
  }
  drawAll();
  if (changed) {
    showBanner("Child " + String(current + 1) + " of " + String(children.size()), COLOR_TEXT, BANNER_MS);
    beep(1400, 70);
  } else {
    updateIdleBanner();
  }
}

// ---- sensor (runs on the UI task) ----------------------------------------------

#ifndef BME68X_USE_FPU
#error "the BME68x driver must report floating point values"
#endif

struct {
  bme68x_dev dev;
  bme68x_conf conf;
  bme68x_heatr_conf heatr;
  bsec_bme_settings_t settings;  // what BSEC last asked for
  Sample latest;                 // the newest outputs, merged as BSEC delivers them
  bool have_temperature = false;
  bool present = false;
  bool measuring = false;
  int fails = 0;
  int64_t control_ns = 0;       // when BSEC asked for the running measurement
  unsigned long next_at = 0;    // when to look for the sensor again (0: now)
  unsigned long ready_at = 0;   // when the running measurement is done
  unsigned long posted_at = 0;  // when a sample was last handed to the sync task (0: never)
  unsigned long saved_at = 0;   // when BSEC's state was last stored (0: not since boot)
} env;

uint8_t* bsec_inst = nullptr;
uint8_t bsec_work[BSEC_MAX_WORKBUFFER_SIZE];

int8_t sensorRead(uint8_t reg, uint8_t* data, uint32_t len, void*) {
  return M5.Ex_I2C.readRegister(SENSOR_ADDR, reg, data, len, SENSOR_I2C_HZ) ? BME68X_INTF_RET_SUCCESS : -1;
}

int8_t sensorWrite(uint8_t reg, const uint8_t* data, uint32_t len, void*) {
  return M5.Ex_I2C.writeRegister(SENSOR_ADDR, reg, data, len, SENSOR_I2C_HZ) ? BME68X_INTF_RET_SUCCESS : -1;
}

void sensorDelay(uint32_t us, void*) {
  if (us >= 1000) delay(us / 1000);
  else delayMicroseconds(us);
}

// BSEC's clock: nanoseconds since boot, which never wraps in practice.
int64_t bsecNowNs() { return esp_timer_get_time() * 1000LL; }

// What BSEC has learned about this room (its baseline) survives a reboot in flash. A state saved
// by another BSEC version is refused by the library, and then it simply starts over.
void bsecSaveState() {
  uint8_t state[BSEC_MAX_STATE_BLOB_SIZE];
  uint32_t n = 0;
  if (bsec_get_state_m(bsec_inst, 0, state, sizeof(state), bsec_work, sizeof(bsec_work), &n) != BSEC_OK || !n) return;
  Preferences prefs;
  prefs.begin("trygg", false);
  prefs.putBytes("bsec", state, n);
  prefs.end();
  env.saved_at = millis() | 1;
}

bool bsecBegin() {
  if (!bsec_inst) bsec_inst = (uint8_t*)malloc(bsec_get_instance_size_m());
  if (!bsec_inst || bsec_init_m(bsec_inst) != BSEC_OK) return false;

  uint8_t state[BSEC_MAX_STATE_BLOB_SIZE];
  Preferences prefs;
  prefs.begin("trygg", true);
  size_t n = prefs.getBytesLength("bsec");
  if (n > 0 && n <= sizeof(state)) prefs.getBytes("bsec", state, n);
  else n = 0;
  prefs.end();
  if (n && bsec_set_state_m(bsec_inst, state, n, bsec_work, sizeof(bsec_work)) != BSEC_OK) {
    Serial.println("BSEC: saved state refused, starting over");
    if (bsec_init_m(bsec_inst) != BSEC_OK) return false;
  }

  // Static IAQ is the variant for a sensor that stays in one room. Compensated temperature and humidity
  // take out the sensor's own heat; the raw pressure and gas resistance ride along.
  const uint8_t wanted[] = {BSEC_OUTPUT_STATIC_IAQ,
                            BSEC_OUTPUT_CO2_EQUIVALENT,
                            BSEC_OUTPUT_BREATH_VOC_EQUIVALENT,
                            BSEC_OUTPUT_SENSOR_HEAT_COMPENSATED_TEMPERATURE,
                            BSEC_OUTPUT_SENSOR_HEAT_COMPENSATED_HUMIDITY,
                            BSEC_OUTPUT_RAW_PRESSURE,
                            BSEC_OUTPUT_RAW_GAS};
  bsec_sensor_configuration_t subscribe[sizeof(wanted)];
  for (size_t i = 0; i < sizeof(wanted); i++) {
    subscribe[i].sensor_id = wanted[i];
    subscribe[i].sample_rate = BSEC_SAMPLE_RATE_LP;
  }
  bsec_sensor_configuration_t needed[BSEC_MAX_PHYSICAL_SENSOR];
  uint8_t n_needed = BSEC_MAX_PHYSICAL_SENSOR;
  if (bsec_update_subscription_m(bsec_inst, subscribe, sizeof(wanted), needed, &n_needed) != BSEC_OK) return false;

  memset(&env.settings, 0, sizeof(env.settings));  // next_call 0: ask BSEC what to do right away
  memset(&env.latest, 0, sizeof(env.latest));
  env.have_temperature = false;
  env.saved_at = 0;
  return true;
}

bool sensorBegin() {
  M5.Ex_I2C.begin();
  env.dev = {};
  env.dev.intf = BME68X_I2C_INTF;
  env.dev.read = sensorRead;
  env.dev.write = sensorWrite;
  env.dev.delay_us = sensorDelay;
  env.dev.amb_temp = 25;
  if (bme68x_init(&env.dev) != BME68X_OK) return false;
  env.conf = {};
  env.conf.filter = BME68X_FILTER_OFF;
  env.conf.odr = BME68X_ODR_NONE;
  env.heatr = {};
  return bsecBegin();
}

// Starts the forced-mode measurement BSEC asked for; the result is collected once it is done, so
// the buttons are never held up by the sensor (the gas heater alone takes 150 ms).
bool sensorStart() {
  const bsec_bme_settings_t& s = env.settings;
  // BSEC's oversampling codes (0-5) are the driver's BME68X_OS_* values.
  env.conf.os_hum = s.humidity_oversampling;
  env.conf.os_temp = s.temperature_oversampling;
  env.conf.os_pres = s.pressure_oversampling;
  env.heatr.enable = s.run_gas ? BME68X_ENABLE : BME68X_DISABLE;
  env.heatr.heatr_temp = s.heater_temperature;
  env.heatr.heatr_dur = s.heater_duration;
  if (bme68x_set_conf(&env.conf, &env.dev) != BME68X_OK) return false;
  if (bme68x_set_heatr_conf(BME68X_FORCED_MODE, &env.heatr, &env.dev) != BME68X_OK) return false;
  if (bme68x_set_op_mode(BME68X_FORCED_MODE, &env.dev) != BME68X_OK) return false;
  uint32_t us = bme68x_get_meas_dur(BME68X_FORCED_MODE, &env.conf, &env.dev) + (uint32_t)s.heater_duration * 1000;
  env.ready_at = millis() + us / 1000 + 5;
  env.measuring = true;
  return true;
}

// Hands one finished measurement to BSEC and keeps the outputs that come back.
bool bsecProcess(const bme68x_data& d) {
  const uint32_t want = env.settings.process_data;
  auto wants = [want](int input) { return (want & (1u << (input - 1))) != 0; };
  bsec_input_t in[BSEC_MAX_PHYSICAL_SENSOR];
  uint8_t n_in = 0;
  auto add = [&](uint8_t id, float value) {
    in[n_in].sensor_id = id;
    in[n_in].signal = value;
    in[n_in].signal_dimensions = 1;
    in[n_in].time_stamp = env.control_ns;
    n_in++;
  };
  if (wants(BSEC_INPUT_HEATSOURCE)) add(BSEC_INPUT_HEATSOURCE, SENSOR_TEMP_OFFSET_C);
  if (wants(BSEC_INPUT_TEMPERATURE)) add(BSEC_INPUT_TEMPERATURE, d.temperature);
  if (wants(BSEC_INPUT_HUMIDITY)) add(BSEC_INPUT_HUMIDITY, d.humidity);
  if (wants(BSEC_INPUT_PRESSURE)) add(BSEC_INPUT_PRESSURE, d.pressure / 100.0f);  // the driver reports Pa
  if (wants(BSEC_INPUT_GASRESISTOR)) add(BSEC_INPUT_GASRESISTOR, d.gas_resistance);
  if (!n_in) return true;

  bsec_output_t out[BSEC_NUMBER_OUTPUTS];
  uint8_t n_out = BSEC_NUMBER_OUTPUTS;
  if (bsec_do_steps_m(bsec_inst, in, n_in, out, &n_out) < BSEC_OK) return false;

  Sample& l = env.latest;
  for (uint8_t i = 0; i < n_out; i++) {
    switch (out[i].sensor_id) {
      case BSEC_OUTPUT_STATIC_IAQ:
        l.iaq = out[i].signal;
        l.iaq_accuracy = out[i].accuracy;
        l.has_iaq = true;
        break;
      case BSEC_OUTPUT_CO2_EQUIVALENT: l.co2_ppm = out[i].signal; break;
      case BSEC_OUTPUT_BREATH_VOC_EQUIVALENT: l.voc_ppm = out[i].signal; break;
      case BSEC_OUTPUT_SENSOR_HEAT_COMPENSATED_TEMPERATURE:
        l.temperature_c = out[i].signal;
        env.have_temperature = true;
        break;
      case BSEC_OUTPUT_SENSOR_HEAT_COMPENSATED_HUMIDITY: l.humidity_pct = out[i].signal; break;
      case BSEC_OUTPUT_RAW_PRESSURE: l.pressure_hpa = out[i].signal; break;
      case BSEC_OUTPUT_RAW_GAS:
        l.gas_ohms = out[i].signal;
        l.has_gas = true;
        break;
    }
  }
  return true;
}

// Posts the newest outputs every SENSOR_PERIOD_MS, and files BSEC's state away once it is calibrated.
void sensorPublish() {
  unsigned long now = millis();
  if (!env.have_temperature) return;
  if (env.latest.has_iaq && env.latest.iaq_accuracy >= 3 && (!env.saved_at || now - env.saved_at > BSEC_SAVE_MS))
    bsecSaveState();
  if (env.posted_at && now - env.posted_at < SENSOR_PERIOD_MS) return;
  env.posted_at = now | 1;
  Sample s = env.latest;
  s.at = clockSynced() ? time(nullptr) : 0;
  Lock lock;
  sample = s;
  sample_ready = true;
}

// Hands the newest outputs to the climate bar on the screen.
void sensorClimate() {
  const Sample& l = env.latest;
  climate.show = env.have_temperature;
  climate.temperature_c = l.temperature_c;
  // BSEC's index is only trusted once it has begun to calibrate (accuracy >= 1).
  if (!l.has_iaq || l.iaq_accuracy < 1) climate.air = 0;
  else if (l.iaq <= 100) climate.air = 1;
  else if (l.iaq <= 150) climate.air = 2;
  else if (l.iaq <= 200) climate.air = 3;
  else climate.air = 4;
}

bool sensorCollect() {
  bme68x_data data;
  uint8_t n = 0;
  if (bme68x_get_data(BME68X_FORCED_MODE, &data, &n, &env.dev) != BME68X_OK || n == 0) return false;
  if (!(data.status & BME68X_NEW_DATA_MSK)) return false;
  if (!(data.status & BME68X_GASM_VALID_MSK)) return true;  // BSEC wants gas readings that took
  if (!bsecProcess(data)) return false;
  sensorClimate();
  sensorPublish();
  return true;
}

void sensorLost(unsigned long now) {
  if (++env.fails < SENSOR_MAX_FAILS) return;
  Serial.println("ENV Pro stopped answering");
  env.present = false;
  climate.show = false;
  env.fails = 0;
  env.next_at = (now + SENSOR_RETRY_MS) | 1;
}

// Called every pass of loop(): finds the sensor (so it can be plugged in after boot), does what BSEC
// asks for when it asks, and hands the outputs to the sync task.
void sensorTick() {
  unsigned long now = millis();
  if (env.measuring) {
    if (now < env.ready_at) return;
    env.measuring = false;
    if (sensorCollect()) env.fails = 0;
    else sensorLost(now);
    return;
  }
  if (env.next_at && now < env.next_at) return;

  if (!env.present) {
    env.present = sensorBegin();
    if (!env.present) {
      env.next_at = (now + SENSOR_RETRY_MS) | 1;
      return;
    }
    env.next_at = 0;
    Serial.println("ENV Pro found");
  }

  int64_t ns = bsecNowNs();
  if (ns < env.settings.next_call) return;
  if (bsec_sensor_control_m(bsec_inst, ns, &env.settings) < BSEC_OK) {
    sensorLost(now);
    return;
  }
  if (!env.settings.trigger_measurement || env.settings.op_mode != BME68X_FORCED_MODE) return;
  env.control_ns = ns;
  if (!sensorStart()) sensorLost(now);
}

// ---- syncing (runs on the sync task) -----------------------------------------

void updateProgress(int done, int total) { update_pct = total > 0 ? (int)((int64_t)done * 100 / total) : 0; }

// A check is due on the first sync after boot, then every UPDATE_CHECK_MS (UPDATE_RETRY_MS
// after one that failed), and only on a device nobody has pressed for a minute: the
// download takes some seconds. Not once an image is installed and waiting for its restart.
bool updateDue() {
  if (restart_pending) return false;
  bool quiet = !last_activity || millis() - last_activity > UPDATE_QUIET_MS;
  return quiet && (!last_update_check || millis() - last_update_check > update_interval);
}

// Asks the server for the newest firmware and installs it when it is newer than this
// build; the UI restarts into it. WiFi is up and the clock set by then (wifiUp), which
// the HTTPS download needs. A download that fails or doesn't match the server's MD5 is
// discarded by the updater and the running firmware carries on.
void checkForUpdate() {
  last_update_check = millis() | 1;  // never 0, which means "not checked yet"
  update_interval = UPDATE_RETRY_MS;  // until a check has worked
  String body;
  int status = request("GET", "/api/v1/firmware/button", "", body);
  if (status == 404) update_interval = UPDATE_CHECK_MS;  // nothing published
  if (status != 200) return;
  JsonDocument doc;
  if (deserializeJson(doc, body)) return;
  update_interval = UPDATE_CHECK_MS;
  int64_t latest = doc["version"].as<int64_t>();
  if (latest <= FW_VERSION) return;

  Serial.printf("Firmware %lld available (running %d), updating\n", (long long)latest, (int)FW_VERSION);
  String url = net.url + "/api/v1/firmware/button/image";
  bool tls = url.startsWith("https://");
  WiFiClient plain;
  WiFiClientSecure secure;
  if (tls) trustBundle(secure);
  WiFiClient& client = tls ? static_cast<WiFiClient&>(secure) : plain;

  httpUpdate.rebootOnUpdate(false);
  httpUpdate.onProgress(updateProgress);
  update_pct = 0;
  auto result = httpUpdate.update(client, url, "", [](HTTPClient* http) {
    http->addHeader("Authorization", "Bearer " + net.token);
  });
  update_pct = -1;
  if (result == HTTP_UPDATE_OK) {
    restart_pending = true;
  } else if (result == HTTP_UPDATE_FAILED) {
    Serial.printf("Update failed: %s\n", httpUpdate.getLastErrorString().c_str());
    update_interval = UPDATE_RETRY_MS;
  }
}

// Posts one queued press. The entry is stamped with when the button was pressed, not
// when it's delivered, and carries its client_id, so a request whose response got
// lost can be repeated without creating a second entry.
int postEntry(const Pending& p) {
  time_t at = p.pressed_at ? p.pressed_at : time(nullptr) - (millis() - p.pressed_ms) / 1000;
  JsonDocument doc;
  doc["type"] = "diaper";
  doc["data"]["kind"] = ACTIONS[p.action].kind;
  doc["started_at"] = isoAt(at);
  doc["client_id"] = p.client_id;
  String body;
  serializeJson(doc, body);
  String response;
  return request("POST", "/api/v1/children/" + String(p.child_id) + "/entries", body, response);
}

// Posts the latest sensor sample to the app, which registers this board as a device the first
// time. A sample the network or server couldn't take goes back for the next try unless a newer
// one has arrived; one the server refuses outright is dropped and the user told, like an entry.
bool deliverSample() {
  Sample s;
  {
    Lock lock;
    if (!sample_ready) return true;
    s = sample;
    sample_ready = false;
  }
  JsonDocument doc;
  doc["model"] = "env_pro";
  doc["temperature_c"] = s.temperature_c;
  doc["humidity_pct"] = s.humidity_pct;
  doc["pressure_hpa"] = s.pressure_hpa;
  if (s.has_gas) doc["gas_ohms"] = s.gas_ohms;
  if (s.has_iaq) {
    doc["iaq"] = s.iaq;
    doc["iaq_accuracy"] = s.iaq_accuracy;
    doc["co2_ppm"] = s.co2_ppm;
    doc["voc_ppm"] = s.voc_ppm;
  }
  if (s.at) doc["measured_at"] = isoAt(s.at);
  String body, response;
  serializeJson(doc, body);
  int status = request("POST", "/api/v1/devices/" + device_id + "/readings", body, response);
  if (status == 200 || status == 201) {
    adoptShortId(response);
    return true;
  }
  if (permanent(status)) {
    postError(describeFailure(status).c_str());
    return true;
  }
  Lock lock;
  if (!sample_ready) {
    sample = s;
    sample_ready = true;
  }
  return false;
}

// Sends the queue oldest first, picking up entries added meanwhile. Returns false
// when the network or server let us down (the entry stays queued). An entry the
// server rejects outright is dropped and the user told, since retrying can't help.
bool deliverQueue() {
  for (;;) {
    Pending p;
    {
      Lock lock;
      if (queue.empty()) return true;
      p = queue.front();  // only this task removes entries, so it's still the head below
    }
    int status = -1;
    for (int attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      status = postEntry(p);
      if (status == 200 || status == 201 || permanent(status)) break;
      vTaskDelay(pdMS_TO_TICKS(500));
    }
    bool sent = status == 200 || status == 201;
    if (!sent && !permanent(status)) return false;
    if (!sent) postError(describeFailure(status).c_str());
    Lock lock;
    queue.erase(queue.begin());
    pending_count = queue.size();
  }
}

bool childrenStale() { return have_children && millis() - child_loaded_at > CHILD_REFRESH_MS; }

bool needsSync() {
  return pending_count > 0 || sample_ready || (!have_children && !fetched_ready) || childrenStale() || updateDue();
}

// One sync: make sure WiFi is up, deliver everything queued (and anything queued
// meanwhile), refresh the children if we have none or they're stale, look for new
// firmware if it's time.
void runSync() {
  if (!needsSync()) {
    syncing = false;
    return;
  }
  syncing = true;
  bool ok = wifiUp();
  bool refreshed = false;
  bool update_checked = false;
  while (ok) {
    if (!deliverQueue()) {
      ok = false;
    } else if (!refreshed && (!have_children || childrenStale())) {
      refreshed = true;
      ok = fetchChildren();
    } else if (sample_ready) {
      ok = deliverSample();
    } else if (!update_checked && updateDue()) {
      update_checked = true;
      checkForUpdate();  // its own back-off; a failed check doesn't fail the sync
    } else if (pending_count == 0) {
      break;
    }
  }
  if (ok) {
    retry_delay = 0;
  } else {
    // Back off while the network or server is down. A new press resets this.
    retry_delay = retry_delay ? min(retry_delay * 2, RETRY_MAX_MS) : RETRY_BASE_MS;
    last_fail_at = millis();
  }
  syncing = false;
}

void syncTask(void*) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    runSync();
  }
}

// ---- logging (runs on the UI task) -----------------------------------------

// Wakes the sync task (a no-op if it's already running; it re-checks the queue
// before switching WiFi off).
void kickSync(bool now) {
  if (now) retry_delay = 0;
  syncing = true;
  xTaskNotify(sync_task, 1, eSetBits);
}

// Queues a press for delivery. The caller gives the feedback; nothing here waits.
bool enqueue(int i) {
  Pending p;
  p.action = i;
  p.child_id = child_id;
  p.pressed_at = clockSynced() ? time(nullptr) : 0;
  p.pressed_ms = millis();
  uuid4(p.client_id);
  Lock lock;
  if (queue.size() >= QUEUE_MAX) return false;
  queue.push_back(p);
  pending_count = queue.size();
  return true;
}

// The click is acknowledged straight away, whatever the network is doing.
void press(int i) {
  const Action& a = ACTIONS[i];
  if (!child_id) {
    // Nothing to attach the entry to until the first children fetch has worked.
    showBanner("Not connected yet", COLOR_ERR, BANNER_MS);
    beep(300, 400);
    kickSync(true);
    return;
  }
  if (!enqueue(i)) {
    showBanner("Too many waiting", COLOR_ERR, BANNER_MS);
    beep(300, 400);
    kickSync(true);
    return;
  }
  kickSync(true);
  String time = localTime();
  last_logged = String(a.label) + (time.length() ? " " + time : "");
  drawLogged(a, time);
  logged_until = millis() + LOGGED_SCREEN_MS;
  successChime();
}

// Leaves the full-screen "logged" view and puts the normal screen back.
void dismissLogged() {
  logged_until = 0;
  drawAll();
  updateIdleBanner();
}

// Picks up what the sync task has to say: a fresh children list, or a failure the
// user should know about (a rejected entry, a bad token).
void showSyncResults() {
  if (fetched_ready) adoptChildren();
  static uint32_t seen_error = 0;
  if (error_seq != seen_error) {
    char msg[sizeof sync_error];
    {
      Lock lock;
      seen_error = error_seq;
      strlcpy(msg, sync_error, sizeof msg);
    }
    showBanner(msg, COLOR_ERR, BANNER_MS);
    beep(300, 400);
  }
}

}  // namespace

void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);
  M5.Display.setBrightness(DAY_BRIGHTNESS);
  M5.Speaker.setVolume(35);
  Serial.begin(115200);
  Serial.printf("Trygg button, firmware %d\n", (int)FW_VERSION);
  setenv("TZ", TIMEZONE, 1);
  tzset();
  loadNetSettings();
  mu = xSemaphoreCreateMutex();
  WiFi.persistent(false);  // don't write the credentials to flash on every join
  WiFi.mode(WIFI_STA);     // powered from the wall: the radio stays on, no modem sleep
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  device_id = WiFi.macAddress();
  xTaskCreatePinnedToCore(syncTask, "sync", 24576, nullptr, 1, &sync_task, 0);  // TLS + the updater need room
  M5.Display.setRotation((SCREEN_ROTATION + 1) & 3);  // our 0 is the Basic panel's default, M5GFX's 1
  lay = layoutFor(SCREEN_ROTATION);
  drawAll();
  kickSync(true);  // the first children fetch
}

void loop() {
  M5.update();
  for (int i = 0; i < 3; i++) {
    if (btn(i).wasPressed()) last_activity = millis();
  }

  static unsigned long last_brightness_check = 0;
  if (!last_brightness_check || millis() - last_brightness_check > BRIGHTNESS_CHECK_MS) {
    last_brightness_check = millis() | 1;  // never 0, which means "not checked yet"
    updateBrightness();
  }

  sensorTick();

  // Retry a failed sync once its back-off is over. Presses and boot kick it directly.
  bool retry_due = retry_delay == 0 || millis() - last_fail_at >= retry_delay;
  if (!syncing && needsSync() && retry_due) kickSync(false);

  // While the green "logged" screen is up every press is ignored (the chime above
  // blocks briefly, so a press made then is read now and dropped here), so a
  // fumbled double tap can't log twice.
  if (logged_until) {
    for (int i = 0; i < 3; i++) {
      if (btn(i).wasPressed()) consumed[i] = true;
    }
    if (millis() > logged_until) dismissLogged();
    delay(10);
    return;
  }

  if (list_open) {
    int moved = 0;
    bool select = false;
    for (int i = 0; i < 3; i++) {
      if (!btn(i).wasPressed()) continue;
      consumed[i] = true;  // none of these may log when let go
      list_until = millis() + LIST_TIMEOUT_MS;
      int a = actionFor(i);  // ▲ is the first in reading order, ▼ the last
      if (a == 0) moved = -1;
      else if (a == 2) moved = 1;
      else select = true;
    }
    int n = children.size();
    if (select) {
      closeList(true);
    } else if (millis() > list_until) {
      closeList(false);
    } else if (moved) {
      list_sel = (list_sel + moved + n) % n;
      drawList();
      beep(moved < 0 ? 900 : 1400, 40);
    }
    delay(10);
    return;
  }

  // A tap logs when the button is let go (so a hold can be told apart); a hold of
  // HOLD_MS acts at once, and its release is swallowed.
  for (int i = 0; i < 3; i++) {
    auto& b = btn(i);
    int a = actionFor(i);  // what this button is, as the screen shows it
    if (b.wasPressed()) consumed[i] = false;
    if (!consumed[i] && b.isPressed() && b.pressedFor(HOLD_MS)) {
      consumed[i] = true;
      if (a == 1) openList();
      else cycleChild(a == 0 ? -1 : 1);
    }
    if (b.wasReleased()) {
      if (!consumed[i]) press(a);
      consumed[i] = false;
    }
    if (logged_until || list_open) break;
  }

  // A press above may have put the green screen up, which these would draw over.
  if (!logged_until && !list_open) {
    if (banner_until && millis() > banner_until) banner_until = 0;
    if (short_id_dirty) {
      short_id_dirty = false;
      drawName();
    }
    updateClimateBar();
    showSyncResults();
    updateIdleBanner();
  }

  // A new image is installed: restart into it once nothing is waiting to be sent (the
  // queue is RAM only) and nobody is using the buttons.
  if (restart_pending && !syncing && pending_count == 0 && !logged_until && !list_open &&
      millis() - last_activity > 5000) {
    showBanner("Updated, restarting…", COLOR_OK);
    delay(1500);
    ESP.restart();
  }
  delay(10);
}
