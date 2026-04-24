#include <M5Unified.h>
#include <esp_mac.h>
#include "ble_bridge.h"
#include "recorder.h"

static char deviceName[20] = "VibeBuddy";
static bool btnAHeld = false;
static uint32_t lastHeartbeat = 0;
static uint32_t heartbeatCount = 0;
static bool linkReported = false;

static bool     prevConnected = false;
static uint16_t prevMtu = 0;
static bool     prevBtnA = false;
static bool     prevLinkReady = false;
static bool     prevLinkFailed = false;
static bool     prevRecording = false;

static void buildDeviceName() {
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_BT);
  snprintf(deviceName, sizeof(deviceName), "VibeBuddy-%02X%02X", mac[4], mac[5]);
}

static void drawScreen() {
  M5.Lcd.fillScreen(BLACK);
  M5.Lcd.setTextColor(WHITE, BLACK);
  M5.Lcd.setTextSize(2);
  M5.Lcd.setCursor(8, 20);
  M5.Lcd.print("Vibe Buddy");

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

  if (M5.BtnA.wasPressed()) {
    btnAHeld = true;
    Serial.println("[btn] A pressed");
    recorderStart();
  }
  if (M5.BtnA.wasReleased()) {
    btnAHeld = false;
    Serial.println("[btn] A released");
    recorderStop();
  }

  drainRx();

  if (!bleConnected()) linkReported = false;
  maybeReportLink();

  recorderTick();

  uint32_t now = millis();
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
      ready != prevLinkReady || failed != prevLinkFailed || rec != prevRecording) {
    prevConnected = conn;
    prevMtu = m;
    prevBtnA = btnAHeld;
    prevLinkReady = ready;
    prevLinkFailed = failed;
    prevRecording = rec;
    drawScreen();
  }

  // Short idle; recorderTick already drains the ring aggressively within
  // a single call, so we only need to yield briefly.
  delay(2);
}
