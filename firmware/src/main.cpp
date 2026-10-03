// Trygg diaper button for the M5Stack Basic.
//
//   A = PEE   B = POO   C = MIXED
//
// Shows the child's name on top and the emoji above each button. A press POSTs a
// diaper entry to the Trygg REST API (see docs/api.md) with the family API token
// from config.h.
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

const unsigned long CHILD_REFRESH_MS = 10UL * 60UL * 1000UL;
const unsigned long BANNER_MS = 4000;
const unsigned long LOGGED_SCREEN_MS = 4000;
const int HTTP_TIMEOUT_MS = 8000;
const int MAX_ATTEMPTS = 3;
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

std::vector<Child> children;  // everything the token can see, as of the last load
int current = -1;             // index into `children`
String child_name;
long child_id = 0;
unsigned long child_loaded_at = 0;
unsigned long banner_until = 0;
unsigned long logged_until = 0;  // full-screen "logged" view is up until then
String last_logged;              // e.g. "PEE 14:32", shown once the full-screen view is gone
bool busy = false;

// Where to connect and who as. Compiled in from config.h on a USB flash, which also saves
// them to the device; an over-the-air image carries none and reads the saved ones.
struct {
  String ssid, password, url, token;
} net;
unsigned long last_activity = 0;  // last button press; updates wait for a quiet device

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

bool connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return true;
  if (!net.ssid.length()) {
    showBanner("Not configured: flash with config.h", COLOR_ERR);
    return false;
  }
  showBanner("Connecting to WiFi…", COLOR_BUSY);
  WiFi.mode(WIFI_STA);
  WiFi.begin(net.ssid.c_str(), net.password.c_str());
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
    M5.update();
    delay(100);
  }
  if (WiFi.status() != WL_CONNECTED) {
    showBanner("No WiFi", COLOR_ERR);
    return false;
  }
  configTime(0, 0, "pool.ntp.org", "time.google.com");
  return true;
}

String isoNow() {
  time_t now = time(nullptr);
  struct tm tm;
  gmtime_r(&now, &tm);
  char buf[25];
  strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", &tm);
  return String(buf);
}

String uuid4() {
  uint8_t b[16];
  esp_fill_random(b, sizeof b);
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  char buf[37];
  snprintf(buf, sizeof buf, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", b[0], b[1], b[2],
           b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
  return String(buf);
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

// Fetches the family's children. Keeps the current child across refreshes; the
// first time, picks the remembered one (see preferredChildId), else the first.
bool loadChild(bool quiet = false) {
  String body;
  int status = request("GET", "/api/v1/children", "", body);
  if (status != 200) {
    if (!quiet) showBanner(describeFailure(status), COLOR_ERR);
    return false;
  }
  JsonDocument doc;
  if (deserializeJson(doc, body)) {
    showBanner("Bad response", COLOR_ERR);
    return false;
  }
  std::vector<Child> loaded;
  bool read_only = false;
  for (JsonVariant c : doc["data"].as<JsonArray>()) {
    loaded.push_back({c["id"].as<long>(), c["name"].as<String>()});
    read_only = read_only || c["role"] == "viewer";
  }
  if (loaded.empty()) {
    showBanner("No children yet", COLOR_ERR);
    return false;
  }
  if (read_only) {
    showBanner("Token is read-only", COLOR_ERR);
    return false;
  }
  long want = child_id ? child_id : preferredChildId();
  children = loaded;
  int idx = 0;
  for (int i = 0; i < (int)children.size(); i++) {
    if (children[i].id == want) idx = i;
  }
  selectChild(idx);
  child_loaded_at = millis();
  if (!list_open) {
    drawName();
    showBanner("Ready", COLOR_DIM);
  }
  return true;
}

void updateProgress(int done, int total) {
  static int shown = -1;
  int pct = total > 0 ? (int)((int64_t)done * 100 / total) : 0;
  if (pct == shown) return;
  shown = pct;
  drawBanner(String("Updating ") + pct + "%", COLOR_BUSY);
}

// Asks the server for the newest firmware and installs it when it is newer than this
// build, then restarts into it. A download that fails or doesn't match the server's MD5
// is discarded by the updater and the running firmware carries on. Returns false when
// the check itself failed, so it is retried sooner than after a successful one.
bool checkForUpdate() {
  String body;
  int status = request("GET", "/api/v1/firmware/button", "", body);
  if (status == 404) return true;  // nothing published
  if (status != 200) return false;
  JsonDocument doc;
  if (deserializeJson(doc, body)) return false;
  int64_t latest = doc["version"].as<int64_t>();
  if (latest <= FW_VERSION) return true;

  Serial.printf("Firmware %lld available (running %d), updating\n", (long long)latest, (int)FW_VERSION);
  showBanner("Updating firmware…", COLOR_BUSY);
  String url = net.url + "/api/v1/firmware/button/image";
  bool tls = url.startsWith("https://");
  WiFiClient plain;
  WiFiClientSecure secure;
  if (tls) trustBundle(secure);
  WiFiClient& client = tls ? static_cast<WiFiClient&>(secure) : plain;

  httpUpdate.rebootOnUpdate(false);
  httpUpdate.onProgress(updateProgress);
  auto result = httpUpdate.update(client, url, "", [](HTTPClient* http) {
    http->addHeader("Authorization", "Bearer " + net.token);
  });
  if (result == HTTP_UPDATE_OK) {
    showBanner("Updated, restarting…", COLOR_OK);
    delay(1500);
    ESP.restart();
  }
  if (result == HTTP_UPDATE_FAILED) {
    Serial.printf("Update failed: %s\n", httpUpdate.getLastErrorString().c_str());
    showBanner("Update failed", COLOR_ERR, BANNER_MS);
    return false;
  }
  return true;
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
  showBanner(changed ? "Child " + String(current + 1) + " of " + String(children.size()) : String("Ready"),
             changed ? COLOR_TEXT : COLOR_DIM, changed ? BANNER_MS : 0);
  if (changed) beep(1400, 70);
}

// ---- logging ---------------------------------------------------------------

// Retried with the same client_id, which makes the API idempotent: a request
// whose response got lost can't create a second entry. Without a synced clock
// there is no started_at to pin, so we send once and let the server stamp it.
bool logDiaper(const Action& a, String& error) {
  JsonDocument doc;
  doc["type"] = "diaper";
  doc["data"]["kind"] = a.kind;
  bool idempotent = clockSynced();
  if (idempotent) {
    doc["started_at"] = isoNow();
    doc["client_id"] = uuid4();
  }
  String body;
  serializeJson(doc, body);

  String path = "/api/v1/children/" + String(child_id) + "/entries";
  int status = -1;
  for (int attempt = 1; attempt <= (idempotent ? MAX_ATTEMPTS : 1); attempt++) {
    if (!connectWifi()) {
      error = "No WiFi";
      return false;
    }
    String response;
    status = request("POST", path, body, response);
    if (status == 200 || status == 201) return true;
    if (status >= 400 && status < 500) break;  // won't get better by retrying
    delay(500);
  }
  error = describeFailure(status);
  return false;
}

void press(int i) {
  if (busy) return;
  busy = true;
  const Action& a = ACTIONS[i];
  setTiles(COLOR_BUSY, i);
  showBanner(String("Logging ") + a.label + "…", COLOR_BUSY);

  String error;
  if (logDiaper(a, error)) {
    String time = localTime();
    last_logged = String(a.label) + (time.length() ? " " + time : "");
    drawLogged(a, time);
    logged_until = millis() + LOGGED_SCREEN_MS;
    successChime();
  } else {
    setTiles(COLOR_ERR, i);
    showBanner(error, COLOR_ERR, BANNER_MS);
    beep(300, 400);
    delay(700);
    setTiles(COLOR_IDLE);
  }
  busy = false;
}

// Leaves the full-screen "logged" view and puts the normal screen back.
void dismissLogged() {
  logged_until = 0;
  drawAll();
  showBanner(last_logged.length() ? "Last: " + last_logged : "Ready", COLOR_DIM);
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
  drawAll();
  if (connectWifi()) loadChild();
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

  if (banner_until && millis() > banner_until) {
    banner_until = 0;
    drawBanner(child_name.length() ? "Ready" : "Not connected", COLOR_DIM);
  }

  // Not set up yet (or a stale name): keep trying in the background.
  bool stale = child_name.length() && millis() - child_loaded_at > CHILD_REFRESH_MS;
  static unsigned long last_try = 0;
  if ((!child_name.length() || stale) && millis() - last_try > 10000) {
    last_try = millis();
    if (connectWifi()) loadChild(stale);
  }

  static unsigned long last_update_check = 0;
  static unsigned long update_interval = 0;
  if (millis() - last_update_check > update_interval && millis() - last_activity > UPDATE_QUIET_MS && clockSynced() &&
      WiFi.status() == WL_CONNECTED) {
    last_update_check = millis();
    update_interval = checkForUpdate() ? UPDATE_CHECK_MS : UPDATE_RETRY_MS;
  }
  delay(10);
}
