#include <M5Unified.h>
#include <esp_mac.h>
#include <stdarg.h>
#include "ble_bridge.h"
#include "recorder.h"

// recorderTick() runs opus_encode() from loop(), and libopus wants far
// more stack than Arduino's 8 KB default for loopTask: the first encode
// of the first session blew it every time, which the ESP32 reports as
//
//   ***ERROR*** A stack overflow in task loopTask has been detected.
//
// then reboots. From the Mac's side that looked nothing like a crash —
// the device stopped sending mid-session and the link only died 4 s
// later on supervision timeout, so it read as "BLE went quiet".
// 32 KB is generous; RAM is at ~17% and the alternative failure mode is
// a reboot loop nobody can diagnose from the host side.
SET_LOOP_TASK_STACK_SIZE(32 * 1024);

static char deviceName[20] = "VibeBuddy";
static bool btnAHeld = false;
static uint32_t lastHeartbeat = 0;
static uint32_t heartbeatCount = 0;

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
static bool     prevRecording = false;

// Battery is read on a 10 s cadence — getBatteryLevel() goes over I²C to
// the PMIC, so we cache the value and only redraw when the level or
// charging state actually changes (see change-detection block in loop()).
static constexpr uint32_t BATTERY_POLL_MS = 10000;
static constexpr uint32_t BOLT_BLINK_MS = 500;
static uint8_t  g_battery = 0;
static bool     g_charging = false;
// USB present, read off VBUS rather than inferred from isCharging().
// isCharging() answers "is the charger IC pushing current right now",
// which on a full battery oscillates as charge terminates, voltage sags,
// and the charger kicks back in. That flapping is fine for the bolt icon
// but useless as a "the user has this thing plugged in" signal — see
// updateBrightness().
static bool     g_usbPowered = false;
static bool     g_boltVisible = false;
static uint32_t lastBatteryPoll = 0;
static uint32_t lastBoltToggle = 0;
static uint8_t  prevBattery = 255;
static bool     prevCharging = false;

// Backlight power management. The LCD + backlight is the single largest
// idle drain on StickS3. We hold full brightness while the user is
// active, drop to a dim "still readable" level after DIM_AFTER_MS, and
// fully off after OFF_AFTER_MS. On USB power we never dim — the user is
// plausibly looking at the device for the charge state, and there's no
// battery to save.
//
// "Activity" = button press, BLE connect/disconnect, or recorder start.
// It deliberately does NOT include front_app pushes from the host: see
// the touchActivity() call site for the measurements that killed that.
static constexpr uint8_t  BRIGHT_FULL = 180;
static constexpr uint8_t  BRIGHT_DIM  = 30;
static constexpr uint8_t  BRIGHT_OFF  = 0;
static constexpr uint32_t DIM_AFTER_MS = 15000;
static constexpr uint32_t OFF_AFTER_MS = 60000;
static uint8_t  currentBrightness = BRIGHT_FULL;
static uint32_t lastActivityMs = 0;

static void touchActivity() { lastActivityMs = millis(); }

static void applyBrightness(uint8_t target) {
  if (target == currentBrightness) return;
  currentBrightness = target;
  M5.Lcd.setBrightness(target);
}

static void updateBrightness() {
  uint8_t target;
  // Keyed on USB presence, NOT isCharging(). With a full battery on USB
  // the charger cycles on and off every few seconds, and this rule used
  // to follow it: screen strobed full/off, CPU strobed 240/80, and the
  // ES8311 warmed and tore down on each flip. VBUS is the signal this
  // rule always meant — "it's plugged in, the user may be looking at the
  // charge state" — and it doesn't move until the cable does.
  if (g_usbPowered) {
    target = BRIGHT_FULL;
  } else {
    uint32_t idle = millis() - lastActivityMs;
    if      (idle < DIM_AFTER_MS) target = BRIGHT_FULL;
    else if (idle < OFF_AFTER_MS) target = BRIGHT_DIM;
    else                          target = BRIGHT_OFF;
  }
  applyBrightness(target);
}

// CPU frequency management. ESP32-S3 idle current scales roughly with
// the active clock, and at 240 MHz the chip dissipates noticeably more
// than at 80 MHz even when loop() is mostly delay()ing — the Idle task
// doesn't enter light sleep without esp_pm_configure(), so the clock
// keeps running. Two speeds based on user engagement:
//   - recording OR screen at full brightness → 240 MHz (responsive)
//   - everything else → 80 MHz (idle, dim, or off)
// BLE controller runs on its own RF clock and tolerates either; I2S /
// audio paths are only active when recording, which forces 240 anyway.
static constexpr uint32_t CPU_HIGH_MHZ = 240;
static constexpr uint32_t CPU_LOW_MHZ  = 80;
static uint32_t currentCpuMhz = CPU_HIGH_MHZ;

static void applyCpuFreq(uint32_t mhz) {
  if (mhz == currentCpuMhz) return;
  setCpuFrequencyMhz(mhz);
  currentCpuMhz = mhz;
  // setCpuFrequencyMhz reconfigures UART dividers internally; no need
  // to re-init Serial. A handful of in-flight bytes may garble.
  Serial.printf("[cpu] -> %u MHz\n", (unsigned)mhz);
}

static void updateCpuFreq() {
  uint32_t target = (recorderActive() || currentBrightness == BRIGHT_FULL)
                    ? CPU_HIGH_MHZ : CPU_LOW_MHZ;
  applyCpuFreq(target);
}

// Power profiling tick — 1 s cadence. AXP2101 on StickS3 does not expose
// a battery-current ADC (M5Unified's getBatteryCurrent() is a stub that
// returns 0 for this PMIC), so we derive a power proxy from the slope of
// the battery voltage over a sliding window. mV/min is monotonic in
// average current draw and is all we need to A/B different configs.
static constexpr uint32_t POWER_LOG_MS = 1000;
static constexpr size_t   SLOPE_WIN    = 60;     // 60 samples * 1 s = 60 s window
static int       g_mv = 0;
static int       g_mvPerMin = 0;
static uint32_t  lastPowerLog = 0;
static int       slopeMv[SLOPE_WIN];
static uint32_t  slopeMs[SLOPE_WIN];
static size_t    slopeIdx = 0;
static bool      slopeFull = false;

static int computeMvPerMin() {
  size_t count = slopeFull ? SLOPE_WIN : slopeIdx;
  if (count < 5) return 0;
  size_t newest = (slopeIdx + SLOPE_WIN - 1) % SLOPE_WIN;
  size_t oldest = slopeFull ? slopeIdx : 0;
  int32_t dmv = slopeMv[newest] - slopeMv[oldest];
  uint32_t dms = slopeMs[newest] - slopeMs[oldest];
  if (dms == 0) return 0;
  return (int)(((int64_t)dmv * 60000) / (int32_t)dms);
}

// Front-app mirror, pushed by the host whenever the macOS frontmost app
// changes ({"type":"front_app","name":"Safari"}). Empty until the first
// push lands. Cleared on disconnect so a stale name doesn't sit on the
// screen suggesting a connection that's gone.
static char g_frontApp[33] = "";
static char prevFrontApp[33] = "";

// Mirror a printf-style line to the host as {"type":"log","msg":"..."}.
// Mac/iOS app already NSLogs every JSON line it receives, so this gives
// us a USB-free log channel for power profiling. Quiet no-op when no
// link is up (Step 0 baseline measurements that need it use the on-screen
// HUD or Serial via Grove UART).
static void bleLogf(const char* fmt, ...) {
  if (!bleConnected()) return;
  char body[160];
  va_list ap;
  va_start(ap, fmt);
  int blen = vsnprintf(body, sizeof(body), fmt, ap);
  va_end(ap);
  if (blen <= 0) return;
  if (blen >= (int)sizeof(body)) blen = sizeof(body) - 1;

  char out[256];
  size_t i = 0;
  i += snprintf(out + i, sizeof(out) - i, "{\"type\":\"log\",\"msg\":\"");
  for (int j = 0; j < blen && i + 4 < sizeof(out); j++) {
    char c = body[j];
    if (c == '"' || c == '\\') { out[i++] = '\\'; out[i++] = c; }
    else if (c == '\n' || c == '\r') { out[i++] = ' '; }
    else { out[i++] = c; }
  }
  i += snprintf(out + i, sizeof(out) - i, "\"}\n");
  bleWrite((const uint8_t*)out, i);
}

// Live readout, painted above the button legend. mV is the absolute
// battery voltage (settles in 30-60 s after USB unplug); mV/min is the
// 60-second sliding-window slope and is our proxy for instantaneous
// power draw — bigger negative number = more current = more heat.
// Magenta to read as instrumentation, not normal UI.
static void drawPowerHud() {
  M5.Lcd.fillRect(0, 170, M5.Lcd.width(), 14, BLACK);
  M5.Lcd.setTextColor(MAGENTA, BLACK);
  M5.Lcd.setTextSize(1);
  M5.Lcd.setCursor(8, 172);
  M5.Lcd.printf("%dmV %d mV/min", g_mv, g_mvPerMin);
  M5.Lcd.setTextColor(WHITE, BLACK);
}

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
  } else if (recorderLinkOk()) {
    M5.Lcd.setTextColor(GREEN, BLACK);
    M5.Lcd.printf("link: %s mtu=%u", blePhy(), (unsigned)bleMtu());
  } else if (bleLinkReady()) {
    // Connected and settled, but the link can't carry audio. Used to be
    // "PHY != 2M"; now 1M is fine and MTU is the thing that can actually
    // be too small, so say that instead of silently refusing to record.
    M5.Lcd.setTextColor(RED, BLACK);
    M5.Lcd.printf("link: mtu=%u too small", (unsigned)bleMtu());
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

  // Where the next utterance will land. macOS host pushes the frontmost
  // app name; iOS host pushes either "Pasteboard" or the focused web page's
  // title/domain. Wire format is the same — we just render whatever name
  // arrived. size 2 fits ~10 chars at 8 px left margin on the 135 px LCD;
  // anything longer truncates to 9 chars + ".." (default GFX font is
  // ASCII-only, no real ellipsis glyph). No label — keeps semantics the
  // same across platforms.
  if (g_frontApp[0] != 0) {
    char shown[12];
    size_t n = strnlen(g_frontApp, sizeof(g_frontApp));
    if (n > 9) {
      memcpy(shown, g_frontApp, 9);
      shown[9] = '.'; shown[10] = '.'; shown[11] = 0;
    } else {
      memcpy(shown, g_frontApp, n + 1);
    }
    M5.Lcd.setTextColor(ORANGE, BLACK);
    M5.Lcd.setTextSize(2);
    M5.Lcd.setCursor(8, 140);
    // Pad to 11 visible chars so a previous-longer name leaves no
    // ghost pixels behind when a shorter one replaces it.
    M5.Lcd.printf("> %-9s", shown);
    M5.Lcd.setTextSize(1);
    M5.Lcd.setTextColor(WHITE, BLACK);
  } else {
    // Wipe the slot so a previously-displayed name doesn't linger after
    // a host disconnect.
    M5.Lcd.fillRect(8, 140, M5.Lcd.width() - 16, 20, BLACK);
  }

  // Power-profiling HUD slot. drawScreen() wipes everything, so we
  // re-paint here too — otherwise the slot stays black for up to 1 s
  // after a status change.
  drawPowerHud();

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

// Pull a single 'name' string out of a tiny JSON object. We don't pull
// in a real JSON parser for the two message shapes the host emits; this
// covers {"type":"front_app","name":"..."} and is deliberately strict
// about quoting. Returns true on a successful copy.
static bool extractJsonName(const char* json, char* out, size_t outCap) {
  const char* k = strstr(json, "\"name\":\"");
  if (!k) return false;
  k += 8;  // past "name":"
  size_t i = 0;
  while (*k && *k != '"' && i + 1 < outCap) {
    if (*k == '\\' && *(k + 1)) {
      // Reverse a few escapes the host might emit (\\ \" \n).
      char esc = *(k + 1);
      char unescaped = 0;
      switch (esc) {
        case '"':  unescaped = '"';  break;
        case '\\': unescaped = '\\'; break;
        case 'n':  unescaped = ' ';  break;  // newlines on a 1-line label = space
        case 't':  unescaped = ' ';  break;
        default:   unescaped = esc;  break;
      }
      out[i++] = unescaped;
      k += 2;
    } else {
      out[i++] = *k++;
    }
  }
  out[i] = 0;
  return i > 0;
}

// drainRx accumulates bytes off the BLE RX ring into a line buffer; on
// each \n we look at the line's "type" tag and dispatch. Today only
// front_app is consumed; unknown types are echoed to serial and dropped.
static void drainRx() {
  static char  buf[256];
  static size_t len = 0;
  while (bleAvailable()) {
    int b = bleRead();
    if (b < 0) break;
    if (b == '\n') {
      buf[len] = 0;
      if (len > 0) {
        if (strstr(buf, "\"type\":\"front_app\"")) {
          char name[sizeof(g_frontApp)] = "";
          if (extractJsonName(buf, name, sizeof(name))) {
            // strncpy is safe here because g_frontApp is sized one larger
            // than name and we always wrote a terminator above.
            strncpy(g_frontApp, name, sizeof(g_frontApp) - 1);
            g_frontApp[sizeof(g_frontApp) - 1] = 0;
            Serial.printf("[front-app] %s\n", g_frontApp);
          }
        } else {
          Serial.printf("[rx] %u: %s\n", (unsigned)len, buf);
        }
      }
      len = 0;
    } else if (len < sizeof(buf) - 1) {
      buf[len++] = (char)b;
    } else {
      // Overflow: drop the line, resync at next \n.
      len = 0;
    }
  }
}

// Carries the link params rather than announcing them once on connect.
//
// The old {"type":"link"} one-shot lost a race roughly half the time: it
// fired as soon as the PHY settled, and a notify that lands before
// CoreBluetooth has finished setNotifyValue() is dropped with no error
// and no retry — so the app sat on "? PHY / MTU 20" over a healthy
// 2M/517 link. Gating on the CCCD being written wasn't enough; the
// device saw the subscription, sent the frame, and it still vanished.
//
// A one-shot with no ack and no retransmit is the wrong shape for this.
// The heartbeat is already here, already 1 Hz, already idempotent — so
// the link params ride along and the app is correct within a second of
// anything, from any starting state. No race left to lose.
static void sendHeartbeat() {
  if (!bleConnected()) return;
  char buf[128];
  int n = snprintf(buf, sizeof(buf),
                   "{\"type\":\"hb\",\"seq\":%u,\"btn_a\":%s,"
                   "\"phy\":\"%s\",\"mtu\":%u}\n",
                   (unsigned)heartbeatCount,
                   btnAHeld ? "true" : "false",
                   blePhy(), (unsigned)bleMtu());
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

void setup() {
  auto cfg = M5.config();
  // StickS3 routes both speaker and mic through the ES8311 codec on a
  // shared I2S. M5Unified's internal speaker setup grabs I2S first and
  // the mic's begin() then fails silently (DMA runs but delivers zeros).
  // We only need mic in phase 1, so disable speaker at board init time.
  cfg.internal_spk = false;
  M5.begin(cfg);
  M5.Lcd.setRotation(0);
  M5.Lcd.setBrightness(BRIGHT_FULL);
  currentBrightness = BRIGHT_FULL;
  touchActivity();
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
  // When the screen is fully off, the first press of either button only
  // wakes the display. The "real" action fires on the next press. This
  // matches phone-style ergonomics and prevents an accidental record /
  // backspace when the user just wants to peek at status.
  static bool aWakeOnly = false;
  static bool bWakeOnly = false;

  if (M5.BtnA.wasPressed()) {
    bool wasOff = (currentBrightness == BRIGHT_OFF);
    touchActivity();
    if (wasOff) {
      aWakeOnly = true;
    } else {
      aPressAt = millis();
      btnAHeld = true;
      Serial.println("[btn] A pressed -> start record (speculative)");
      recorderStart();
    }
  }
  if (M5.BtnA.wasReleased()) {
    if (aWakeOnly) {
      aWakeOnly = false;
    } else if (btnAHeld) {
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
  }

  // ---- BtnB: click = backspace, long-hold = clear-all --------------------
  if (M5.BtnB.wasPressed()) {
    bool wasOff = (currentBrightness == BRIGHT_OFF);
    touchActivity();
    if (wasOff) {
      bWakeOnly = true;
    } else {
      bPressAt = millis();
      bLongFired = false;
    }
  }
  if (!bWakeOnly && !bLongFired && M5.BtnB.isPressed() &&
      millis() - bPressAt >= CLICK_MS_B) {
    bLongFired = true;
    sendEditAction("clear");
  }
  if (M5.BtnB.wasReleased()) {
    if (bWakeOnly) {
      bWakeOnly = false;
    } else {
      if (!bLongFired) {
        sendEditAction("backspace");
      }
      bLongFired = false;
    }
  }

  drainRx();


  recorderTick();

  uint32_t now = millis();

  // Power profiling tick. Sample mV, push into the slope ring, recompute
  // slope, repaint the HUD, and (if connected) shove a log line at the
  // host. The slope is our proxy for current draw on this PMIC.
  if (lastPowerLog == 0 || now - lastPowerLog >= POWER_LOG_MS) {
    lastPowerLog = now;
    g_mv = (int)M5.Power.getBatteryVoltage();
    slopeMv[slopeIdx] = g_mv;
    slopeMs[slopeIdx] = now;
    slopeIdx = (slopeIdx + 1) % SLOPE_WIN;
    if (slopeIdx == 0) slopeFull = true;
    g_mvPerMin = computeMvPerMin();
    drawPowerHud();
    Serial.printf("[pwr] mv=%d mv_per_min=%d conn=%d rec=%d btnA=%d bl=%u cpu=%u\n",
                  g_mv, g_mvPerMin,
                  bleConnected() ? 1 : 0,
                  recorderActive() ? 1 : 0,
                  btnAHeld ? 1 : 0,
                  (unsigned)currentBrightness,
                  (unsigned)currentCpuMhz);
    bleLogf("mv=%d mv_per_min=%d conn=%d rec=%d btnA=%d bl=%u cpu=%u",
            g_mv, g_mvPerMin,
            bleConnected() ? 1 : 0,
            recorderActive() ? 1 : 0,
            btnAHeld ? 1 : 0,
            (unsigned)currentBrightness,
            (unsigned)currentCpuMhz);
  }

  if (lastBatteryPoll == 0 || now - lastBatteryPoll >= BATTERY_POLL_MS) {
    lastBatteryPoll = now;
    int lvl = M5.Power.getBatteryLevel();
    if (lvl < 0) lvl = 0;
    if (lvl > 100) lvl = 100;
    g_battery = (uint8_t)lvl;
    g_charging = M5.Power.isCharging();
    // VBUS is only exposed on AXP192/AXP2101 boards; StickS3 is AXP2101.
    // -1 means the model doesn't support it, in which case fall back to
    // isCharging() and accept the flapping rather than never dimming.
    int16_t vbus = M5.Power.getVBUSVoltage();
    g_usbPowered = (vbus < 0) ? g_charging : (vbus > 4000);
    // StickS3 has no fuel gauge — M5Unified estimates SOC linearly from
    // mV (3300→0%, 4100→100%). During Li-Po CV charging, voltage holds
    // near 4.1V for the bulk of the charge, so level can read 100% for
    // a long time. Logging mV lets us tell saturation from a real stall.
    int16_t mv = M5.Power.getBatteryVoltage();
    Serial.printf("[bat] mv=%d level=%u chg=%d vbus=%d usb=%d\n",
                  (int)mv, (unsigned)g_battery, g_charging ? 1 : 0,
                  (int)vbus, g_usbPowered ? 1 : 0);
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
  bool rec = recorderActive();
  // Wipe the front-app slot on disconnect so a stale name doesn't sit
  // there suggesting a live link. Reconnect will repopulate via the
  // host's link-ready resend.
  if (!conn && g_frontApp[0] != 0) {
    g_frontApp[0] = 0;
  }
  if (conn != prevConnected || m != prevMtu || btnAHeld != prevBtnA ||
      ready != prevLinkReady || rec != prevRecording ||
      g_battery != prevBattery || g_charging != prevCharging ||
      strncmp(g_frontApp, prevFrontApp, sizeof(g_frontApp)) != 0) {
    // Link-level changes count as user activity: they're rare, and a
    // connect really does mean someone just walked up / woke their Mac.
    //
    // front_app deliberately does NOT. It used to, on the theory that a
    // real app switch means the user is at their desk and might glance
    // over. Measured over 31 minutes of ordinary Mac use, that theory
    // costs:
    //
    //   backlight at full   55.7% of the time
    //   CPU at 240 MHz      55.7% of the time
    //   front_app pushes    50, i.e. one every 37 s
    //
    // The wake window is 15 s, so anything under a ~15 s switching
    // cadence pins the screen on permanently. The device spent over half
    // its life lit and at full clock without anyone touching it — dwarfing
    // every BLE parameter we were about to tune for power. Switching
    // windows on the host is host-side state, not someone looking at a
    // stick in their pocket.
    //
    // The name still renders when the screen happens to be on: the outer
    // condition redraws on any of these, and only the wake timer is
    // gated here.
    if (conn != prevConnected || ready != prevLinkReady || rec != prevRecording) {
      touchActivity();
    }
    prevConnected = conn;
    prevMtu = m;
    prevBtnA = btnAHeld;
    prevLinkReady = ready;
    prevRecording = rec;
    prevBattery = g_battery;
    prevCharging = g_charging;
    strncpy(prevFrontApp, g_frontApp, sizeof(prevFrontApp) - 1);
    prevFrontApp[sizeof(prevFrontApp) - 1] = 0;
    drawScreen();
  }

  updateBrightness();
  updateCpuFreq();
  // Pre-warm the mic codec while the user is plausibly about to press
  // BtnA — i.e., screen is at full brightness AND the BLE link is
  // ready. Removes the ~100 ms cold-start gap, which is 100 ms of speech
  // that otherwise never gets captured at all.
  //
  // Full brightness is a proxy for "user is engaged", and since
  // updateBrightness() pins FULL on USB, that proxy is permanently true
  // while plugged in — so the codec stays warm rather than being
  // released on dim. Deliberate: there's no battery to protect on wall
  // power, and it buys back the first 100 ms on every press. On battery
  // the old behavior stands, warm for DIM_AFTER_MS after real activity.
  recorderSetMicWarm(bleLinkReady() && currentBrightness == BRIGHT_FULL);

  // Short idle; recorderTick already drains the ring aggressively within
  // a single call, so we only need to yield briefly.
  delay(2);
}
