// Trygg diaper button for the M5Stack Basic.
//
//   A = PEE   B = POO   C = MIXED
//
// Shows the child's name on top and the emoji above each button. A press POSTs a
// diaper entry to the Trygg REST API (see docs/api.md) with the family API token
// from config.h.
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <M5Unified.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <time.h>

#include "config.h"
#include "icons.h"

namespace {

constexpr uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) { return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3); }

const uint16_t COLOR_BG = rgb(16, 20, 24);  // keep in sync with BG in tools/gen_icons.py
const uint16_t COLOR_TEXT = rgb(255, 255, 255);
const uint16_t COLOR_DIM = rgb(140, 148, 156);
const uint16_t COLOR_IDLE = rgb(48, 56, 64);
const uint16_t COLOR_BUSY = rgb(240, 180, 40);
const uint16_t COLOR_OK = rgb(60, 200, 110);
const uint16_t COLOR_ERR = rgb(230, 70, 70);

struct Action {
  const char* kind;  // API value of data.kind
  const char* label;
  const uint16_t* icon;
  int center_x;  // above the matching physical button
};

const Action ACTIONS[3] = {
    {"pee", "PEE", ICON_PEE, 66},
    {"poo", "POO", ICON_POO, 160},
    {"mixed", "MIXED", ICON_MIXED, 254},
};

const int TILE_W = 84;
const int TILE_Y = 112;
const int TILE_H = 120;

const unsigned long CHILD_REFRESH_MS = 10UL * 60UL * 1000UL;
const unsigned long BANNER_MS = 4000;
const int HTTP_TIMEOUT_MS = 8000;
const int MAX_ATTEMPTS = 3;

String child_name;
long child_id = TRYGG_CHILD_ID;
unsigned long child_loaded_at = 0;
unsigned long banner_until = 0;
bool busy = false;

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

void showBanner(const String& text, uint16_t color, unsigned long ms = 0) {
  drawBanner(text, color);
  banner_until = ms ? millis() + ms : 0;
}

void beep(int hz, int ms) { M5.Speaker.tone(hz, ms); }

// ---- network ---------------------------------------------------------------

bool connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return true;
  showBanner("Connecting to WiFi…", COLOR_BUSY);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
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

bool clockSynced() { return time(nullptr) > 1700000000; }

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

// Sends one request and returns the HTTP status (negative on transport errors).
// `out` receives the response body.
int request(const char* method, const String& path, const String& body, String& out) {
  String url = String(TRYGG_URL) + path;
  bool tls = url.startsWith("https://");
  WiFiClient plain;
  WiFiClientSecure secure;
  if (tls) {
    // Verify against the CA bundle built into the Arduino core. Needs a synced
    // clock for the certificate dates.
    extern const uint8_t rootca_crt_bundle_start[] asm("_binary_x509_crt_bundle_start");
    secure.setCACertBundle(rootca_crt_bundle_start);
  }
  HTTPClient http;
  http.setConnectTimeout(HTTP_TIMEOUT_MS);
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!(tls ? http.begin(secure, url) : http.begin(plain, url))) return -1;
  http.addHeader("Authorization", "Bearer " TRYGG_TOKEN);
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
  JsonArray children = doc["data"].as<JsonArray>();
  JsonVariant chosen;
  for (JsonVariant c : children) {
    if (child_id == 0 || c["id"].as<long>() == child_id) {
      chosen = c;
      break;
    }
  }
  if (chosen.isNull()) {
    showBanner(child_id ? "Child not in this family" : "No children yet", COLOR_ERR);
    return false;
  }
  if (chosen["role"] == "viewer") {
    showBanner("Token is read-only", COLOR_ERR);
    return false;
  }
  child_id = chosen["id"].as<long>();
  child_name = chosen["name"].as<String>();
  child_loaded_at = millis();
  drawName();
  showBanner("Ready", COLOR_DIM);
  return true;
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
    setTiles(COLOR_OK, i);
    showBanner(String(a.label) + " logged", COLOR_OK, BANNER_MS);
    beep(1800, 90);
  } else {
    setTiles(COLOR_ERR, i);
    showBanner(error, COLOR_ERR, BANNER_MS);
    beep(300, 400);
  }
  delay(700);
  setTiles(COLOR_IDLE);
  busy = false;
}

}  // namespace

void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);
  M5.Display.setBrightness(90);
  M5.Speaker.setVolume(60);
  Serial.begin(115200);
  drawAll();
  if (connectWifi()) loadChild();
}

void loop() {
  M5.update();

  if (M5.BtnA.wasPressed()) press(0);
  else if (M5.BtnB.wasPressed()) press(1);
  else if (M5.BtnC.wasPressed()) press(2);

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
  delay(10);
}
