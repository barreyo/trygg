// Trygg diaper button for the M5Stack Basic.
//
//   A = PEE   B = POO   C = MIXED
//
// Shows the child's name on top and the emoji above each button.
//
// Built for battery life: WiFi is off except while a sync runs. A press is
// acknowledged on the spot (green screen + chime) and put on a queue. A background
// task then joins WiFi, POSTs the queued diaper entries to the Trygg REST API (see
// docs/api.md) with the family API token from config.h, and switches WiFi off again.
// The UI never waits on the network, so presses made mid-sync are queued as well.
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <HTTPUpdate.h>
#include <M5Unified.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <time.h>

#include <vector>

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
  int center_x;  // above the matching physical button
};

const Action ACTIONS[3] = {
    {"pee", "PEE", ICON_PEE, ICON_PEE_BIG, 66},
    {"poo", "POO", ICON_POO, ICON_POO_BIG, 160},
    {"mixed", "MIXED", ICON_MIXED, ICON_MIXED_BIG, 254},
};

const int TILE_W = 84;
const int TILE_Y = 112;
const int TILE_H = 120;

const unsigned long CHILD_REFRESH_MS = 60UL * 60UL * 1000UL;  // names refresh whenever WiFi is up and they're older
const unsigned long BANNER_MS = 4000;
const unsigned long LOGGED_SCREEN_MS = 4000;
const int HTTP_TIMEOUT_MS = 8000;
const int MAX_ATTEMPTS = 3;  // per entry, per sync, before backing off
const size_t QUEUE_MAX = 20;
const unsigned long WIFI_FAST_JOIN_MS = 6000;  // rejoining the last-used access point
const unsigned long WIFI_JOIN_MS = 15000;      // full scan
const unsigned long CLOCK_WAIT_MS = 10000;     // first NTP sync after boot
const unsigned long RETRY_BASE_MS = 15000;     // after a failed sync, doubling...
const unsigned long RETRY_MAX_MS = 5UL * 60UL * 1000UL;  // ...up to this
const unsigned long HOLD_MS = 800;           // long press: left/right switch child, middle lists them
const unsigned long LIST_TIMEOUT_MS = 10000;  // the picker closes itself after this much quiet
const int LIST_ROWS = 5;

// Over-the-air updates: look for a newer release this often, but only once the device has
// been left alone for a while (an update takes a few seconds and ignores the buttons).
const unsigned long UPDATE_CHECK_MS = 6UL * 60UL * 60UL * 1000UL;
const unsigned long UPDATE_RETRY_MS = 15UL * 60UL * 1000UL;
const unsigned long UPDATE_QUIET_MS = 60UL * 1000UL;

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

// ---- drawing ---------------------------------------------------------------

void drawName() {
  auto& d = M5.Display;
  d.fillRect(0, 0, d.width(), 56, COLOR_BG);
  d.setTextColor(COLOR_TEXT, COLOR_BG);
  d.setTextDatum(middle_center);
  const lgfx::IFont* fonts[] = {&fonts::lgfxJapanGothic_32, &fonts::lgfxJapanGothic_24, &fonts::lgfxJapanGothic_16};
  String text = child_name.length() ? child_name : String("Trygg");
  for (auto font : fonts) {
    d.setFont(font);
    if (d.textWidth(text) <= d.width() - 16) break;
  }
  d.drawString(text, d.width() / 2, 28);
}

// One line under the name: what just happened, or the connection state.
void drawBanner(const String& text, uint16_t color) {
  shown_banner = text;
  auto& d = M5.Display;
  d.fillRect(0, 60, d.width(), 44, COLOR_BG);
  d.setTextColor(color, COLOR_BG);
  d.setTextDatum(middle_center);
  d.setFont(&fonts::lgfxJapanGothic_20);
  if (d.textWidth(text) > d.width() - 8) d.setFont(&fonts::lgfxJapanGothic_16);
  d.drawString(text, d.width() / 2, 82);
}

void drawTile(int i, uint16_t border) {
  auto& d = M5.Display;
  const Action& a = ACTIONS[i];
  int x = a.center_x - TILE_W / 2;
  d.fillRoundRect(x, TILE_Y, TILE_W, TILE_H, 10, COLOR_BG);
  d.drawRoundRect(x, TILE_Y, TILE_W, TILE_H, 10, border);
  d.drawRoundRect(x + 1, TILE_Y + 1, TILE_W - 2, TILE_H - 2, 9, border);
  d.pushImage(a.center_x - ICON_SIZE / 2, TILE_Y + 10, ICON_SIZE, ICON_SIZE, a.icon);
  d.setTextColor(COLOR_TEXT, COLOR_BG);
  d.setTextDatum(middle_center);
  d.setFont(&fonts::lgfxJapanGothic_20);
  d.drawString(a.label, a.center_x, TILE_Y + 96);
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
  d.fillScreen(COLOR_OK_BG);
  d.pushImage(d.width() / 2 - ICON_BIG_SIZE / 2, 14, ICON_BIG_SIZE, ICON_BIG_SIZE, a.icon_big);
  d.setTextColor(COLOR_TEXT, COLOR_OK_BG);
  d.setTextDatum(middle_center);
  d.setFont(&fonts::lgfxJapanGothic_32);
  d.drawString(String(a.label) + " logged", d.width() / 2, 140);
  if (time.length()) {
    d.setFont(&fonts::Font7);  // big 7-segment digits
    d.drawString(time, d.width() / 2, 196);
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

// The child picker: ▲ / OK / ▼ above the three buttons.
void drawList() {
  auto& d = M5.Display;
  int n = children.size();
  d.fillScreen(COLOR_BG);
  d.setTextColor(COLOR_DIM, COLOR_BG);
  d.setTextDatum(middle_center);
  d.setFont(&fonts::lgfxJapanGothic_20);
  d.drawString("Choose child", d.width() / 2, 16);

  int top = max(0, min(list_sel - LIST_ROWS / 2, n - LIST_ROWS));
  for (int r = 0; r < LIST_ROWS && top + r < n; r++) {
    int idx = top + r;
    int y = 34 + r * 34;
    bool sel = idx == list_sel;
    if (sel) {
      d.fillRoundRect(12, y, d.width() - 24, 32, 8, COLOR_IDLE);
      d.drawRoundRect(12, y, d.width() - 24, 32, 8, COLOR_BUSY);
    }
    d.setTextColor(sel ? COLOR_TEXT : COLOR_DIM, sel ? COLOR_IDLE : COLOR_BG);
    d.setTextDatum(middle_left);
    fitFont(children[idx].name, d.width() - 80);
    d.drawString(children[idx].name, 28, y + 16);
    if (idx == current) d.fillCircle(d.width() - 30, y + 16, 5, COLOR_OK);
  }

  d.fillTriangle(ACTIONS[0].center_x, 214, ACTIONS[0].center_x - 10, 230, ACTIONS[0].center_x + 10, 230, COLOR_TEXT);
  d.fillTriangle(ACTIONS[2].center_x, 230, ACTIONS[2].center_x - 10, 214, ACTIONS[2].center_x + 10, 214, COLOR_TEXT);
  d.setTextColor(COLOR_TEXT, COLOR_BG);
  d.setTextDatum(middle_center);
  d.setFont(&fonts::lgfxJapanGothic_20);
  d.drawString("OK", ACTIONS[1].center_x, 222);
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
  prefs.end();
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

// Joins the network and makes sure the clock is set (entries are stamped with it, and
// TLS needs it). Rejoining the access point we used last time skips the channel scan,
// which keeps the radio on for a second or two less.
bool wifiUp() {
  static bool have_ap = false;
  static uint8_t ap_bssid[6];
  static int32_t ap_channel = 0;

  if (!net.ssid.length()) {
    static bool reported = false;
    if (!reported) postError("Not configured: flash with config.h");
    reported = true;
    return false;
  }
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(false);
  bool joined = false;
  if (have_ap) {
    WiFi.begin(net.ssid.c_str(), net.password.c_str(), ap_channel, ap_bssid);
    joined = waitJoined(WIFI_FAST_JOIN_MS);
    if (!joined) WiFi.disconnect();
  }
  if (!joined) {
    WiFi.begin(net.ssid.c_str(), net.password.c_str());
    joined = waitJoined(WIFI_JOIN_MS);
  }
  if (!joined) return false;
  have_ap = true;
  ap_channel = WiFi.channel();
  memcpy(ap_bssid, WiFi.BSSID(), sizeof ap_bssid);

  // Re-syncing on every join keeps the drift of the (WiFi-less) clock in check. Only
  // the very first sync after boot is worth waiting for.
  configTime(0, 0, "pool.ntp.org", "time.google.com");
  unsigned long start = millis();
  while (!clockSynced() && millis() - start < CLOCK_WAIT_MS) vTaskDelay(pdMS_TO_TICKS(100));
  return clockSynced();
}

void wifiOff() {
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
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

bool needsSync() { return pending_count > 0 || (!have_children && !fetched_ready) || updateDue(); }

// One sync: WiFi up, deliver everything queued (and anything queued meanwhile),
// refresh the children if we have none or they're stale, look for new firmware if it's
// time, WiFi down.
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
    } else if (!refreshed && (!have_children || millis() - child_loaded_at > CHILD_REFRESH_MS)) {
      refreshed = true;
      ok = fetchChildren();
    } else if (!update_checked && updateDue()) {
      update_checked = true;
      checkForUpdate();  // its own back-off; a failed check doesn't fail the sync
    } else if (pending_count == 0) {
      break;
    }
  }
  wifiOff();
  if (ok) {
    retry_delay = 0;
  } else {
    // Back off, so being out of range doesn't flatten the battery. A new press resets this.
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
  WiFi.mode(WIFI_OFF);     // the radio stays off until there is something to send
  xTaskCreatePinnedToCore(syncTask, "sync", 24576, nullptr, 1, &sync_task, 0);  // TLS + the updater need room
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
      if (i == 0) moved = -1;
      else if (i == 2) moved = 1;
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
    if (b.wasPressed()) consumed[i] = false;
    if (!consumed[i] && b.isPressed() && b.pressedFor(HOLD_MS)) {
      consumed[i] = true;
      if (i == 1) openList();
      else cycleChild(i == 0 ? -1 : 1);
    }
    if (b.wasReleased()) {
      if (!consumed[i]) press(i);
      consumed[i] = false;
    }
    if (logged_until || list_open) break;
  }

  // A press above may have put the green screen up, which these would draw over.
  if (!logged_until && !list_open) {
    if (banner_until && millis() > banner_until) banner_until = 0;
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
