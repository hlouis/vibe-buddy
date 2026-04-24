#include "recorder.h"
#include "ble_bridge.h"
#include <M5Unified.h>
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <string.h>

// 16 kHz mono 16-bit -> 32 KB/s. Ring holds ~500 ms so the BLE drain can
// breathe through a short stall without dropping samples.
static constexpr uint32_t SAMPLE_RATE = 16000;
static constexpr size_t RING_SAMPLES = 16384;   // 32 KB @ int16
static constexpr size_t CHUNK_SAMPLES = 512;    // 32 ms per mic read

// Ping-pong buffers fed into M5.Mic.record(). With a single buffer,
// M5Unified's async queue can race: record() returns immediately after
// queueing, and isRecording() may briefly read false before DMA actually
// starts, letting us read stale data. Two buffers let us queue buf[i+1]
// before we process buf[i] so DMA is never idle AND the buf being read
// is never the buf being filled.
static int16_t chunkBufs[2][CHUNK_SAMPLES];

static int16_t* ring = nullptr;
static volatile size_t ringHead = 0;
static volatile size_t ringTail = 0;
static volatile bool   active = false;
static volatile bool   stopPending = false;
static volatile uint16_t frameSeq = 0;
static volatile uint32_t bytesSent = 0;
static volatile uint32_t overruns = 0;

static inline size_t ringAvail() {
  return (ringHead + RING_SAMPLES - ringTail) % RING_SAMPLES;
}

static void recorderTask(void*) {
  int recIdx = 0;   // buf currently being filled by DMA
  bool primed = false;
  uint32_t chunkCount = 0;

  for (;;) {
    if (!active) {
      // Drain any in-flight DMA so next session starts clean.
      if (primed) {
        while (M5.Mic.isRecording()) vTaskDelay(1);
        primed = false;
      }
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }

    // Prime: queue the first buffer so DMA can start filling while we
    // loop back to wait. Subsequent iterations re-queue inside the body.
    if (!primed) {
      if (!M5.Mic.record(chunkBufs[recIdx], CHUNK_SAMPLES, SAMPLE_RATE)) {
        vTaskDelay(pdMS_TO_TICKS(1));
        continue;
      }
      primed = true;
    }

    // Wait for the currently-queued buf to finish filling.
    while (M5.Mic.isRecording()) {
      vTaskDelay(1);
      if (!active) break;
    }
    if (!active) continue;

    // The just-finished buffer. Flip the index and queue the NEXT record
    // BEFORE we touch the finished one, so DMA stays hot (no gap).
    int doneIdx = recIdx;
    recIdx ^= 1;
    M5.Mic.record(chunkBufs[recIdx], CHUNK_SAMPLES, SAMPLE_RATE);

    // Now process doneIdx at our leisure while DMA fills recIdx.
    int16_t* done = chunkBufs[doneIdx];

    chunkCount++;
    if ((chunkCount & 0x0F) == 0) {
      int16_t peak = 0;
      for (size_t i = 0; i < CHUNK_SAMPLES; i++) {
        int16_t v = done[i];
        if (v < 0) v = -v;
        if (v > peak) peak = v;
      }
      Serial.printf("[mic] chunk=%u peak=%d\n", (unsigned)chunkCount, (int)peak);
    }

    // Spill into ring. Overrun: drop oldest (advance tail) so recent
    // speech survives.
    for (size_t i = 0; i < CHUNK_SAMPLES; i++) {
      size_t next = (ringHead + 1) % RING_SAMPLES;
      if (next == ringTail) {
        ringTail = (ringTail + 1) % RING_SAMPLES;
        overruns++;
      }
      ring[ringHead] = done[i];
      ringHead = next;
    }
  }
}

void recorderInit() {
  ring = (int16_t*)ps_malloc(RING_SAMPLES * sizeof(int16_t));
  if (!ring) {
    Serial.println("[rec] PSRAM alloc failed");
    return;
  }
  Serial.printf("[rec] ring %u samples allocated in PSRAM\n", (unsigned)RING_SAMPLES);

  // M5.Mic on StickS3 auto-configures ES8311 + I2S. Defaults apply a
  // heavy digital magnification (16x) which saturates any normal-voice
  // input. Drop it to 1 and enable the mild noise filter so clipping
  // goes away and room noise gets suppressed.
  auto mcfg = M5.Mic.config();
  mcfg.magnification = 1;
  mcfg.noise_filter_level = 64;  // cheap 1-pole HP; kills DC + low hiss
  mcfg.sample_rate = SAMPLE_RATE;
  M5.Mic.config(mcfg);

  if (!M5.Mic.begin()) {
    Serial.println("[rec] M5.Mic.begin() failed");
    return;
  }
  Serial.println("[rec] M5.Mic ready");

  // Core 0 runs Arduino loop + BLE stack; put the mic reader on core 1
  // so audio DMA handling never stalls behind BLE notify bookkeeping.
  xTaskCreatePinnedToCore(recorderTask, "recorder", 4096, nullptr, 5, nullptr, 1);
}

void recorderStart() {
  if (active) return;
  if (!bleLinkReady()) {
    Serial.println("[rec] refused start: BLE link not ready (need 2M PHY)");
    return;
  }
  ringHead = ringTail = 0;
  frameSeq = 0;
  bytesSent = 0;
  overruns = 0;
  stopPending = false;
  active = true;

  char buf[80];
  int n = snprintf(buf, sizeof(buf),
                   "{\"type\":\"audio\",\"event\":\"start\",\"sample_rate\":%u}\n",
                   (unsigned)SAMPLE_RATE);
  bleWrite((const uint8_t*)buf, (size_t)n);
  Serial.printf("[rec] start @ %u Hz\n", (unsigned)SAMPLE_RATE);
}

void recorderStop() {
  if (!active) return;
  active = false;
  stopPending = true;
  Serial.println("[rec] stop requested, draining");
}

bool recorderActive()          { return active; }
uint32_t recorderBytesSent()   { return bytesSent; }
uint16_t recorderFrameSeq()    { return frameSeq; }
uint32_t recorderOverruns()    { return overruns; }

// Called from main loop. Drain whatever's in the ring and blast BLE
// frames until empty or until bleWrite backpressure slows us.
void recorderTick() {
  if (!ring) return;

  // Derive max PCM payload from the live MTU. Frame header = 6 bytes, and
  // ble_bridge internally caps notify payload at 244. Keep payload even
  // so we never split a 16-bit sample across frames.
  uint16_t mtu = bleMtu();
  size_t notifyCap = mtu > 3 ? (size_t)(mtu - 3) : 20;
  if (notifyCap > 500) notifyCap = 500;
  size_t maxPayload = notifyCap > 6 ? notifyCap - 6 : 14;
  maxPayload &= ~size_t(1);

  static uint8_t frame[512];    // header + up to ~494 bytes payload

  while (true) {
    size_t avail = ringAvail();
    if (avail == 0) break;

    size_t samples = avail;
    size_t payloadBytes = samples * 2;
    if (payloadBytes > maxPayload) payloadBytes = maxPayload;
    size_t sendSamples = payloadBytes / 2;

    frame[0] = 0xFF;
    frame[1] = 0xAA;
    frame[2] = (uint8_t)(frameSeq & 0xFF);
    frame[3] = (uint8_t)((frameSeq >> 8) & 0xFF);
    frame[4] = (uint8_t)(payloadBytes & 0xFF);
    frame[5] = (uint8_t)((payloadBytes >> 8) & 0xFF);

    // Copy samples out of the ring, little-endian on-wire.
    for (size_t i = 0; i < sendSamples; i++) {
      int16_t s = ring[(ringTail + i) % RING_SAMPLES];
      frame[6 + i * 2]     = (uint8_t)(s & 0xFF);
      frame[6 + i * 2 + 1] = (uint8_t)((s >> 8) & 0xFF);
    }

    size_t wrote = bleWrite(frame, 6 + payloadBytes);
    if (wrote == 0) {
      // Not connected or write failed; leave samples for next tick.
      break;
    }
    ringTail = (ringTail + sendSamples) % RING_SAMPLES;
    frameSeq++;
    bytesSent += payloadBytes;
  }

  if (stopPending && !active && ringAvail() == 0) {
    stopPending = false;
    const char* s = "{\"type\":\"audio\",\"event\":\"stop\"}\n";
    bleWrite((const uint8_t*)s, strlen(s));
    Serial.printf("[rec] stopped: frames=%u bytes=%u overruns=%u\n",
                  (unsigned)frameSeq, (unsigned)bytesSent, (unsigned)overruns);
  }
}
