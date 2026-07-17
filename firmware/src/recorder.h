#pragma once
#include <stdint.h>
#include <stddef.h>

// Mic-to-BLE audio pipeline.
//
// A FreeRTOS task pinned to core 1 pulls PCM off the ES8311 codec via
// M5.Mic and pushes 16-bit samples into a PSRAM ring buffer. The main
// loop (core 0) drains the ring, Opus-encodes whole 60 ms frames, and
// writes binary frames to BLE:
//
//   [0xFF 0xAA][seq:u16 LE][len:u16 LE][one Opus packet]
//
// One frame is one ATT notify — the host's parser depends on that, so
// sendOpusFrame() range-checks against the live MTU. seq resets to 0 on
// every recorderStart() and increments per frame, including ones dropped
// for backpressure, so the host can spot loss.

void recorderInit();         // call once after bleInit()
void recorderStart();        // BtnA press -> begin session, send audio/start
void recorderStop();         // BtnA release -> end session, drain + audio/stop
void recorderCancel();       // short click after speculative start -> abort + audio/cancel
bool recorderActive();       // true while a session is open
void recorderTick();         // main-loop pump: ring -> encode -> BLE frames

// True when the link can actually carry audio: connected, PHY settled,
// and MTU big enough for a whole Opus frame in one notify. recorderStart()
// refuses otherwise — this is the same predicate, exposed so the UI can
// say *why* rather than silently doing nothing.
//
// This replaced "2M PHY negotiated" as the gate. 1M carries Opus fine;
// MTU is what actually constrains us now.
bool recorderLinkOk();

// Hint that the user may press BtnA imminently — bring the ES8311 codec
// up ahead of time so recorderStart() doesn't pay the ~100 ms PLL/DMA
// warm-up cost. Pass false when the device is going idle to release the
// codec; teardown is deferred to the recorder task to avoid racing DMA.
// No-op while a session is active (we never tear down mid-recording).
void recorderSetMicWarm(bool warm);

// Stats for UI / logging
uint32_t recorderBytesSent();
uint16_t recorderFrameSeq();
uint32_t recorderOverruns(); // samples dropped because ring was full
