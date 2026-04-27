#include <M5Unified.h>
#include <esp_mac.h>
#include "ble_bridge.h"
#include "recorder.h"

static char deviceName[20] = "VibeBuddy";
static bool btnAHeld = false;
static uint32_t lastHeartbeat = 0;
static uint32_t heartbeatCount = 0;
static bool linkReported = false;

// Button discrimination:
// BtnA — click (< CLICK_MS_A) = newline,  hold = start/stop recording
// BtnB — click (< CLICK_MS_B) = backspace, long-hold = clear-all
//
// BtnA uses *speculative* recording: on press we start mic + BLE session
// immediately so the user sees REC feedback with zero lag. If the release
// arrives before the click threshold, we emit audio/cancel and a newline
// edit action instead. The ~200 ms of captured audio is harmless (Mac
// tears down the in-flight STT session cleanly).
//
// Click threshold 350 ms: research shows < 250 ms produces many false
// long-press detections; 500 ms is the generic UI default. We sit in the
// middle — because our "long" intent (record) is the *common* one, we
// bias slightly shorter than the generic 500 ms.
//
// BtnB fires clear-all on threshold crossing (700 ms held) for immediate
// visual feedback on a destructive action; backspace fires on release.
static constexpr uint32_t CLICK_MS_A = 350;
static constexpr uint32_t CLICK_MS_B = 700;

static uint32_t aPressAt = 0;

static uint32_t bPressAt = 0;
static bool bLongFired = false;  // true once we've fired the clear-all

static bool     prevConnected = false;
static uint16_t prevMtu = 0;
static bool     prevBtnA = false;
static bool     prevLinkReady = false;
static bool     prevLinkFailed = false;
static bool     prevRecording = false;

// Battery is read on a 10 s cadence — getBatteryLevel() goes over I²C to
// the PMIC, so we cache the value and only redraw when the level or
// charging state actually changes (see change-detection block in loop()).
static constexpr uint32_t BATTERY_POLL_MS = 10000;
static constexpr uint32_t BOLT_BLINK_MS = 500;
static uint8_t  g_battery = 0;
static bool     g_charging = false;
static bool     g_boltVisible = false;
static uint32_t lastBatteryPoll = 0;
static uint32_t lastBoltToggle = 0;
static uint8_t  prevBattery = 255;
static bool     prevCharging = false;

static void buildDeviceName() {
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_BT);
  snprintf(deviceName, sizeof(deviceName), "VibeBuddy-%02X%02X", mac[4], mac[5]);
}

static void drawBattery() {
  // The 22 px fillable width gives ~0.22 px per percent — invisible on
  // mid-range changes. The numeric label carries the real precision; the
  // bar is just at-a-glance color coding.
  constexpr int W = 24, H = 10;
  const int x = M5.Lcd.width() - W - 6;
  const int y = 4;

  uint16_t color;
  if (g_charging)          color = CYAN;
  else if (g_battery > 50) color = GREEN;
  else if (g_battery > 20) color = YELLOW;
  else                     color = RED;

  M5.Lcd.drawRect(x, y, W, H, WHITE);
  M5.Lcd.fillRect(x + W, y + 3, 2, H - 6, WHITE);

  int fillW = ((W - 2) * (int)g_battery) / 100;
  if (fillW < 0) fillW = 0;
  if (fillW > W - 2) fillW = W - 2;
  M5.Lcd.fillRect(x + 1, y + 1, W - 2, H - 2, BLACK);
  if (fillW > 0) {
    M5.Lcd.fillRect(x + 1, y + 1, fillW, H - 2, color);
  }

  // Lightning bolt overlay, blinks at 1 Hz while charging. Two triangles
  // approximate a Z-shape; YELLOW on whatever fill color reads cleanly.
  if (g_charging && g_boltVisible) {
    const int cx = x + W / 2;
    const int cy = y + H / 2;
    M5.Lcd.fillTriangle(cx + 2, cy - 3, cx - 2, cy + 1, cx + 1, cy + 1, YELLOW);
    M5.Lcd.fillTriangle(cx - 2, cy + 3, cx + 2, cy - 1, cx - 1, cy - 1, YELLOW);
  }

  // Numeric label, right-aligned to the bar's left edge. Width budget:
  // "+100%" = 5 chars * 6 px = 30 px at text size 1.
  char label[8];
  snprintf(label, sizeof(label), "%s%u%%",
           g_charging ? "+" : "", (unsigned)g_battery);
  int label_w = (int)strlen(label) * 6;
  M5.Lcd.setTextColor(WHITE, BLACK);
  M5.Lcd.setTextSize(1);
  M5.Lcd.fillRect(x - 34, y + 1, 32, 8, BLACK);
  M5.Lcd.setCursor(x - 4 - label_w, y + 1);
  M5.Lcd.print(label);
}

static void drawScreen() {
  M5.Lcd.fillScreen(BLACK);
  M5.Lcd.setTextColor(WHITE, BLACK);
  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(8, 20);
  M5.Lcd.print("Vibe Buddy");

  drawBattery();

  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(8, 60);
  M5.Lcd.printf("name: %s", deviceName);

  M5.Lcd.setCursor(8, 80);
  if (!bleConnected()) {
    M5.Lcd.setTextColor(YELLOW, BLACK);
    M5.Lcd.print("link: advertising");
  } else if (bleLinkReady()) {
    M5.Lcd.setTextColor(GREEN, BLACK);
    M5.Lcd.printf("link: %s mtu=%u", blePhy(), (unsigned)bleMtu());
  } else if (bleLinkFailed()) {
    M5.Lcd.setTextColor(RED, BLACK);
    M5.Lcd.printf("link: PHY %s (need 2M)", blePhy());
  } else {
    M5.Lcd.setTextColor(CYAN, BLACK);
    M5.Lcd.print("link: negotiating...");
  }
  M5.Lcd.setTextColor(WHITE, BLACK);

  M5.Lcd.setCursor(8, 110);
  if (recorderActive()) {
    M5.Lcd.setTextColor(RED, BLACK);
    M5.Lcd.print("REC  ");
    M5.Lcd.setTextColor(WHITE, BLACK);
    M5.Lcd.printf("seq=%u", (unsigned)recorderFrameSeq());
  } else if (btnAHeld) {
    M5.Lcd.setTextColor(YELLOW, BLACK);
    M5.Lcd.print("BtnA: held (no link)");
  } else {
    M5.Lcd.setTextColor(WHITE, BLACK);
    M5.Lcd.print("hold A to record    ");
  }

  // Button legend, bottom-aligned. Keeps the operator oriented without
  // crowding the status area above; muted color so it reads as chrome.
  M5.Lcd.drawFastHLine(8, 200, 120, DARKGREY);
  M5.Lcd.setTextColor(DARKGREY, BLACK);
  M5.Lcd.setCursor(8, 210);
  M5.Lcd.print("A tap=Enter hold=Rec");
  M5.Lcd.setCursor(8, 222);
  M5.Lcd.print("B tap=BkSp  hold=Clr");
  M5.Lcd.setTextColor(WHITE, BLACK);
}

static void drainRx() {
  if (!bleAvailable()) return;
  char line[256];
  size_t n = 0;
  while (bleAvailable() && n < sizeof(line) - 1) {
    int b = bleRead();
    if (b < 0) break;
    line[n++] = (char)b;
  }
  line[n] = 0;
  Serial.printf("[rx] %u bytes: %s\n", (unsigned)n, line);
}

static void sendHeartbeat() {
  if (!bleConnected()) return;
  char buf[96];
  int n = snprintf(buf, sizeof(buf),
                   "{\"type\":\"hb\",\"seq\":%u,\"btn_a\":%s}\n",
                   (unsigned)heartbeatCount,
                   btnAHeld ? "true" : "false");
  bleWrite((const uint8_t*)buf, (size_t)n);
}

static void sendEditAction(const char* action) {
  if (!bleConnected()) return;
  char buf[64];
  int n = snprintf(buf, sizeof(buf),
                   "{\"type\":\"edit\",\"action\":\"%s\"}\n", action);
  bleWrite((const uint8_t*)buf, (size_t)n);
  Serial.printf("[edit] %s\n", action);
}

static void maybeReportLink() {
  if (!bleLinkReady() || linkReported) return;
  char buf[64];
  int n = snprintf(buf, sizeof(buf),
                   "{\"type\":\"link\",\"phy\":\"%s\",\"mtu\":%u}\n",
                   blePhy(), (unsigned)bleMtu());
  bleWrite((const uint8_t*)buf, (size_t)n);
  linkReported = true;
  Serial.printf("[link] ready: phy=%s mtu=%u\n", blePhy(), (unsigned)bleMtu());
}

void setup() {
  auto cfg = M5.config();
  // StickS3 routes both speaker and mic through the ES8311 codec on a
  // shared I2S. M5Unified's internal speaker setup grabs I2S first and
  // the mic's begin() then fails silently (DMA runs but delivers zeros).
  // We only need mic in phase 1, so disable speaker at board init time.
  cfg.internal_spk = false;
  M5.begin(cfg);
  M5.Lcd.setRotation(0);
  M5.Lcd.setBrightness(180);
  Serial.begin(115200);
  delay(200);
  Serial.println();
  Serial.println("[boot] Vibe Buddy firmware - phase 1 step 4");
  Serial.printf("[boot] psram free: %u bytes\n", (unsigned)ESP.getFreePsram());

  buildDeviceName();
  Serial.printf("[boot] device name: %s\n", deviceName);
  bleInit(deviceName);
  recorderInit();

  drawScreen();
}

void loop() {
  M5.update();

  // ---- BtnA: speculative start on press, decide on release --------------
  // Why speculative: starting mic immediately gives zero-latency REC
  // feedback on the screen. If the release arrives before CLICK_MS_A we
  // simply tell Mac to cancel — no audio was ever sent to Doubao because
  // Mac holds off on the WebSocket until ~400 ms of audio accumulates.
  if (M5.BtnA.wasPressed()) {
    aPressAt = millis();
    btnAHeld = true;
    Serial.println("[btn] A pressed -> start record (speculative)");
    recorderStart();
  }
  if (M5.BtnA.wasReleased()) {
    btnAHeld = false;
    uint32_t held = millis() - aPressAt;
    if (held < CLICK_MS_A) {
      Serial.printf("[btn] A click %ums -> cancel + newline\n", (unsigned)held);
      recorderCancel();
      sendEditAction("newline");
    } else {
      Serial.printf("[btn] A released after %ums -> stop record\n", (unsigned)held);
      recorderStop();
    }
  }

  // ---- BtnB: click = backspace, long-hold = clear-all --------------------
  if (M5.BtnB.wasPressed()) {
    bPressAt = millis();
    bLongFired = false;
  }
  if (!bLongFired && M5.BtnB.isPressed() &&
      millis() - bPressAt >= CLICK_MS_B) {
    bLongFired = true;
    sendEditAction("clear");
  }
  if (M5.BtnB.wasReleased()) {
    if (!bLongFired) {
      sendEditAction("backspace");
    }
    bLongFired = false;
  }

  drainRx();

  if (!bleConnected()) linkReported = false;
  maybeReportLink();

  recorderTick();

  uint32_t now = millis();
  if (lastBatteryPoll == 0 || now - lastBatteryPoll >= BATTERY_POLL_MS) {
    lastBatteryPoll = now;
    int lvl = M5.Power.getBatteryLevel();
    if (lvl < 0) lvl = 0;
    if (lvl > 100) lvl = 100;
    g_battery = (uint8_t)lvl;
    g_charging = M5.Power.isCharging();
    // StickS3 has no fuel gauge — M5Unified estimates SOC linearly from
    // mV (3300→0%, 4100→100%). During Li-Po CV charging, voltage holds
    // near 4.1V for the bulk of the charge, so level can read 100% for
    // a long time. Logging mV lets us tell saturation from a real stall.
    int16_t mv = M5.Power.getBatteryVoltage();
    Serial.printf("[bat] mv=%d level=%u chg=%d\n",
                  (int)mv, (unsigned)g_battery, g_charging ? 1 : 0);
  }

  // Bolt blink — local repaint only; full drawScreen() at 2 Hz would
  // flicker. drawBattery() repaints just its own region.
  if (g_charging) {
    if (now - lastBoltToggle >= BOLT_BLINK_MS) {
      lastBoltToggle = now;
      g_boltVisible = !g_boltVisible;
      drawBattery();
    }
  } else if (g_boltVisible) {
    g_boltVisible = false;
    drawBattery();
  }

  // Silence the 1 Hz heartbeat during recording so JSON doesn't fight
  // audio frames for BLE air time. Still tick the counter.
  if (now - lastHeartbeat >= 1000) {
    lastHeartbeat = now;
    heartbeatCount++;
    if (!recorderActive()) {
      Serial.printf("[tick] %u conn=%d phy=%s mtu=%u btnA=%d\n",
                    (unsigned)heartbeatCount,
                    bleConnected() ? 1 : 0,
                    blePhy(),
                    (unsigned)bleMtu(),
                    btnAHeld ? 1 : 0);
      sendHeartbeat();
    } else {
      Serial.printf("[rec-tick] seq=%u bytes=%u overruns=%u\n",
                    (unsigned)recorderFrameSeq(),
                    (unsigned)recorderBytesSent(),
                    (unsigned)recorderOverruns());
    }
  }

  bool conn = bleConnected();
  uint16_t m = bleMtu();
  bool ready = bleLinkReady();
  bool failed = bleLinkFailed();
  bool rec = recorderActive();
  if (conn != prevConnected || m != prevMtu || btnAHeld != prevBtnA ||
      ready != prevLinkReady || failed != prevLinkFailed || rec != prevRecording ||
      g_battery != prevBattery || g_charging != prevCharging) {
    prevConnected = conn;
    prevMtu = m;
    prevBtnA = btnAHeld;
    prevLinkReady = ready;
    prevLinkFailed = failed;
    prevRecording = rec;
    prevBattery = g_battery;
    prevCharging = g_charging;
    drawScreen();
  }

  // Short idle; recorderTick already drains the ring aggressively within
  // a single call, so we only need to yield briefly.
  delay(2);
}
