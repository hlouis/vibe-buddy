#pragma once
#include <stdint.h>
#include <stddef.h>

// Mic-to-BLE audio pipeline.
//
// A FreeRTOS task pinned to core 1 pulls PCM off the ES8311 codec via
// M5.Mic and pushes 16-bit samples into a PSRAM ring buffer. The main
// loop (core 0) drains the ring and writes binary frames to BLE:
//
//   [0xFF 0xAA][seq:u16 LE][len:u16 LE][PCM...]
//
// Framing is sized to fit the negotiated MTU so each frame is one ATT
// notify. seq resets to 0 on every recorderStart().

void recorderInit();         // call once after bleInit()
void recorderStart();        // BtnA press -> begin session, send audio/start
void recorderStop();         // BtnA release -> end session, drain + audio/stop
bool recorderActive();       // true while a session is open
void recorderTick();         // main-loop pump: ring -> BLE frames

// Stats for UI / logging
uint32_t recorderBytesSent();
uint16_t recorderFrameSeq();
uint32_t recorderOverruns(); // samples dropped because ring was full
