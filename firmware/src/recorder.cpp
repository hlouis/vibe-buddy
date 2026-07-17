#include "recorder.h"
#include "ble_bridge.h"
#include <M5Unified.h>
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <string.h>
#include <opus.h>

// Mic captures 16 kHz mono 16-bit (32 KB/s of PCM); we Opus-encode it to
// ~2.8 KB/s before it ever touches the radio. The ring still holds raw
// PCM — encoding happens at drain time in recorderTick — and buys ~500 ms
// of slack so the BLE drain can breathe through a short stall.
static constexpr uint32_t SAMPLE_RATE = 16000;
static constexpr size_t RING_SAMPLES = 16384;   // 32 KB @ int16
static constexpr size_t CHUNK_SAMPLES = 512;    // 32 ms per mic read

// Opus. 60 ms is the largest frame Opus allows, and we want the largest:
// it minimizes notifies/sec and header overhead on a link where those,
// not raw throughput, are the scarce resource. 960 samples @ 16 kHz.
//
// CBR 20 kbps -> ~150 B/packet, comfortably inside one notify. Complexity
// 1 keeps the encoder off the critical path (this runs in recorderTick on
// the main loop). DTX stays OFF: it would let the encoder skip silent
// frames, but the host's Ogg muxer advances granule per delivered packet,
// so silently-dropped frames would desync the timeline. Not worth it for
// a push-to-talk device that only transmits while a button is held.
static constexpr int OPUS_FRAME_SAMPLES = 960;
static constexpr int OPUS_BITRATE = 20000;
static constexpr size_t OPUS_MAX_PACKET = 256;

// Ceiling on frames encoded per recorderTick(). The drain condition is
// "ring has >= one frame", and the mic task on core 1 refills it at one
// frame per 60 ms — so if encoding were ever slower than realtime, an
// unbounded loop would never see the ring empty and would never return.
// The main loop (and with it the BLE stack, on the same core) would
// starve, and the host would see the link die on supervision timeout
// with no crash to explain it.
//
// The cap turns that into a graceful degradation instead: the ring backs
// up, the existing overrun path drops oldest and logs it. loop() spins
// every ~2 ms, so 4 frames/tick is ~200 frames/s of drain capacity
// against the 16.7 frames/s the mic actually produces — over 10x margin.
//
// Measured on hardware: one 60 ms frame costs 19-22 ms to encode at
// complexity 1 on a 240 MHz S3 — a third of realtime, not the 2-5 ms
// guessed when this was written. It varies with content (silence is
// cheaper than speech), so treat the high end as the real number.
// Two implicit dependencies fall out of that, so they're written down
// here rather than rediscovered the hard way:
//
//  1. CPU stays at 240 MHz for the whole session. main.cpp's DFS keys on
//     recorderActive(), so this holds today — but at 80 MHz the same
//     frame would cost ~66 ms and blow the 60 ms budget outright.
//  2. OPUS_SET_COMPLEXITY stays low. Raising it eats the margin directly.
//
// Break either and encoding goes slower than realtime; the cap is then
// the only thing keeping loop() returning at all.
static constexpr int MAX_ENCODES_PER_TICK = 4;

// Hard cap on a single session. A physically stuck BtnA (or one wedged
// by a wet finger / case pressure) otherwise records forever: the mic
// stays hot, we blast 32 KB/s over BLE, and the Mac holds a Doubao
// WebSocket open indefinitely — which bills per second. We stop rather
// than cancel so whatever was said in the window still gets transcribed.
// The host's PTTSession watchdog (maxHoldSec = 30) only covers
// host-side triggers; nothing upstream watches the device button.
static constexpr uint32_t MAX_RECORD_MS = 60000;

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
static volatile uint32_t startedAt = 0;
// Last opus_encode() duration. Surfaced in the stop log: the budget is
// 60000 us (one frame of audio per frame of wall clock) and anything
// approaching that means the drain cap above is the only thing between
// us and a starved BLE stack.
static volatile uint32_t encodeUs = 0;

// ES8311 codec lifecycle. Power-on is non-trivial (~50-100 ms incl. PLL
// lock + DMA setup) but holding the codec live across long idle periods
// dissipates the analog frontend continuously. We bring it up on
// recorderStart and tear it down inside the recorder task itself once
// drain completes — never from the main thread, so we don't race the
// in-flight DMA. micShutdownPending is the cross-thread signal.
static volatile bool micUp = false;
static volatile bool micShutdownPending = false;

// Opus encoder. Created once at init and reset per session rather than
// created/destroyed per press: opus_encoder_create for 16 kHz mono is a
// ~20 KB allocation, and doing that on the PTT press edge would add
// latency to the exact path we spent effort making fast. Unlike the
// ES8311 it costs no analog power to leave instantiated.
static OpusEncoder* opusEnc = nullptr;

// One encoded packet awaiting a retry. opus_encode is stateful, so the
// PCM path's "leave the samples in the ring and re-send next tick" trick
// is not available to us: by then the encoder has advanced past this
// frame and re-encoding the same PCM would splice a frame encoded
// against the wrong state into the stream. So we consume the PCM once,
// and park the *encoded* packet here if the link pushes back.
static uint8_t pendingPkt[OPUS_MAX_PACKET];
static size_t  pendingLen = 0;

static bool micBringUp() {
  if (micUp) return true;
  auto mcfg = M5.Mic.config();
  mcfg.magnification = 1;
  mcfg.noise_filter_level = 64;
  mcfg.sample_rate = SAMPLE_RATE;
  M5.Mic.config(mcfg);
  if (!M5.Mic.begin()) {
    Serial.println("[rec] M5.Mic.begin() failed");
    return false;
  }
  micUp = true;
  Serial.println("[rec] mic up");
  return true;
}

static inline size_t ringAvail() {
  return (ringHead + RING_SAMPLES - ringTail) % RING_SAMPLES;
}

static bool opusBringUp() {
  if (opusEnc) return true;
  int err = OPUS_OK;
  opusEnc = opus_encoder_create(SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &err);
  if (!opusEnc || err != OPUS_OK) {
    Serial.printf("[rec] opus_encoder_create failed: %d\n", err);
    opusEnc = nullptr;
    return false;
  }
  opus_encoder_ctl(opusEnc, OPUS_SET_VBR(0));                    // CBR: predictable packet size
  opus_encoder_ctl(opusEnc, OPUS_SET_BITRATE(OPUS_BITRATE));
  opus_encoder_ctl(opusEnc, OPUS_SET_DTX(0));                    // see comment on OPUS_FRAME_SAMPLES
  opus_encoder_ctl(opusEnc, OPUS_SET_COMPLEXITY(1));
  opus_encoder_ctl(opusEnc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
  Serial.printf("[rec] opus encoder up: %u Hz mono CBR %d bps, %d ms frames\n",
                (unsigned)SAMPLE_RATE, OPUS_BITRATE,
                OPUS_FRAME_SAMPLES * 1000 / (int)SAMPLE_RATE);
  return true;
}

// Frame and ship one Opus packet. Returns false if the link pushed back,
// in which case the caller must park the packet — it cannot be rebuilt.
static bool sendOpusFrame(const uint8_t* pkt, size_t len) {
  static uint8_t frame[6 + OPUS_MAX_PACKET];
  frame[0] = 0xFF;
  frame[1] = 0xAA;
  frame[2] = (uint8_t)(frameSeq & 0xFF);
  frame[3] = (uint8_t)((frameSeq >> 8) & 0xFF);
  frame[4] = (uint8_t)(len & 0xFF);
  frame[5] = (uint8_t)((len >> 8) & 0xFF);
  memcpy(frame + 6, pkt, len);
  if (bleWrite(frame, 6 + len) == 0) return false;
  frameSeq++;
  bytesSent += len;
  return true;
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
      // Honor a pending codec shutdown. Only safe to call here, after
      // primed==false, so M5.Mic.end() doesn't race in-flight DMA. Done
      // on this task (not main) for the same reason.
      if (micShutdownPending && micUp) {
        M5.Mic.end();
        micUp = false;
        micShutdownPending = false;
        Serial.println("[rec] mic down");
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

  // Build the encoder now, not on the first press: it's a ~20 KB malloc
  // and the PTT press edge is the one path we care about the latency of.
  // Unlike the ES8311 it draws no analog power sitting idle, so there's
  // nothing to gain by deferring it. recorderStart() re-checks and only
  // resets state.
  opusBringUp();

  // ES8311 / I2S start-up is deferred to recorderStart(). Keeping the
  // codec powered through long idle periods was a measurable share of
  // baseline current draw; we accept the ~50 ms warm-up cost on the
  // first press of each session in exchange.
  //
  // Core 0 runs Arduino loop + BLE stack; put the mic reader on core 1
  // so audio DMA handling never stalls behind BLE notify bookkeeping.
  // The task is started here even though the mic isn't up yet — it
  // sits in the !active branch doing vTaskDelay until needed.
  xTaskCreatePinnedToCore(recorderTask, "recorder", 4096, nullptr, 5, nullptr, 1);
}

void recorderStart() {
  if (active) return;
  if (!bleLinkReady()) {
    Serial.println("[rec] refused start: BLE link not ready (need 2M PHY)");
    return;
  }
  // Cancel any pending teardown — we're about to need the codec.
  micShutdownPending = false;
  if (!micBringUp()) {
    Serial.println("[rec] start aborted: codec failed to come up");
    return;
  }
  if (!opusBringUp()) {
    Serial.println("[rec] start aborted: opus encoder unavailable");
    micShutdownPending = true;
    return;
  }
  // Fresh encoder state per session — otherwise the first packets of a
  // new press are predicted against the tail of the previous one.
  opus_encoder_ctl(opusEnc, OPUS_RESET_STATE);
  ringHead = ringTail = 0;
  frameSeq = 0;
  bytesSent = 0;
  overruns = 0;
  pendingLen = 0;
  stopPending = false;
  startedAt = millis();
  active = true;

  // "codec" is new as of the on-device Opus change. Hosts that predate
  // it ignore the key and assume PCM — which is why the field is
  // additive rather than a version bump.
  char buf[96];
  int n = snprintf(buf, sizeof(buf),
                   "{\"type\":\"audio\",\"event\":\"start\",\"sample_rate\":%u,\"codec\":\"opus\"}\n",
                   (unsigned)SAMPLE_RATE);
  bleWrite((const uint8_t*)buf, (size_t)n);
  Serial.printf("[rec] start @ %u Hz opus\n", (unsigned)SAMPLE_RATE);
}

void recorderStop() {
  if (!active) return;
  active = false;
  stopPending = true;
  Serial.println("[rec] stop requested, draining");
}

// Abort a speculatively-started session without flushing anything. Used
// when the BtnA hold turned out to be a short click — we kick it off on
// press for instant REC feedback, then if the release came too soon we
// call this to undo cleanly. Mac side sees audio/cancel and wipes the
// half-formed ASR session.
void recorderCancel() {
  if (!active && !stopPending) return;
  active = false;
  stopPending = false;
  ringHead = ringTail = 0;
  pendingLen = 0;
  micShutdownPending = true;   // task will end() the codec on its idle pass
  const char* s = "{\"type\":\"audio\",\"event\":\"cancel\"}\n";
  bleWrite((const uint8_t*)s, strlen(s));
  Serial.printf("[rec] cancelled after frames=%u bytes=%u\n",
                (unsigned)frameSeq, (unsigned)bytesSent);
}

void recorderSetMicWarm(bool warm) {
  if (active) return;             // never disturb a live session
  if (warm) {
    micShutdownPending = false;
    micBringUp();                 // idempotent
  } else if (micUp) {
    micShutdownPending = true;    // task will end() on next idle pass
  }
}

bool recorderActive()          { return active; }
uint32_t recorderBytesSent()   { return bytesSent; }
uint16_t recorderFrameSeq()    { return frameSeq; }
uint32_t recorderOverruns()    { return overruns; }

// Called from main loop. Drain whatever's in the ring and blast BLE
// frames until empty or until bleWrite backpressure slows us.
void recorderTick() {
  if (!ring) return;

  // Enforce the session cap before draining, so this tick already starts
  // flushing the tail. recorderStop() is safe to call under a still-held
  // BtnA: main.cpp's release path calls it again and it no-ops on
  // !active, and start only ever fires on a press edge — so a stuck
  // button stays stopped instead of immediately re-arming.
  if (active && millis() - startedAt >= MAX_RECORD_MS) {
    Serial.printf("[rec] hit %us cap — forcing stop (button stuck?)\n",
                  (unsigned)(MAX_RECORD_MS / 1000));
    recorderStop();
  }

  // Retry a parked packet before encoding anything new — otherwise we'd
  // emit frames out of order.
  if (pendingLen > 0) {
    if (!sendOpusFrame(pendingPkt, pendingLen)) return;   // link still stuck
    pendingLen = 0;
  }

  static int16_t encBuf[OPUS_FRAME_SAMPLES];
  static uint8_t pkt[OPUS_MAX_PACKET];

  // Encode whole 60 ms frames only. Opus has no partial-frame concept:
  // a short tail would have to be zero-padded, and since the host trims
  // the trailing window anyway (release click), padding it would be
  // fabricating audio nobody will ever hear. Leftovers < 960 samples are
  // dropped at stop.
  int encoded = 0;
  while (opusEnc && encoded < MAX_ENCODES_PER_TICK &&
         ringAvail() >= (size_t)OPUS_FRAME_SAMPLES) {
    for (int i = 0; i < OPUS_FRAME_SAMPLES; i++) {
      encBuf[i] = ring[(ringTail + i) % RING_SAMPLES];
    }
    // Consume the PCM up front: the encoder state has moved on, so
    // these samples can never be re-encoded into an equivalent packet.
    ringTail = (ringTail + OPUS_FRAME_SAMPLES) % RING_SAMPLES;

    uint32_t t0 = micros();
    int n = opus_encode(opusEnc, encBuf, OPUS_FRAME_SAMPLES, pkt, sizeof(pkt));
    encodeUs = micros() - t0;
    encoded++;
    if (n < 0) {
      Serial.printf("[rec] opus_encode failed: %d\n", n);
      continue;
    }
    if (n <= 2) continue;   // DTX/comfort-noise stub; we run with DTX off

    if (!sendOpusFrame(pkt, (size_t)n)) {
      memcpy(pendingPkt, pkt, (size_t)n);
      pendingLen = (size_t)n;
      return;
    }
  }

  if (stopPending && !active && ringAvail() < (size_t)OPUS_FRAME_SAMPLES && pendingLen == 0) {
    stopPending = false;
    const char* s = "{\"type\":\"audio\",\"event\":\"stop\"}\n";
    bleWrite((const uint8_t*)s, strlen(s));
    Serial.printf("[rec] stopped: frames=%u bytes=%u overruns=%u enc=%uus/60000us\n",
                  (unsigned)frameSeq, (unsigned)bytesSent, (unsigned)overruns,
                  (unsigned)encodeUs);
    // Drain done — release the codec. Recorder task will pick this up
    // on its next idle pass and call M5.Mic.end() safely.
    micShutdownPending = true;
  }
}
