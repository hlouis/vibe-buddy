#pragma once
#include <stdint.h>
#include <stddef.h>

// Nordic UART Service-compatible BLE bridge. Clients subscribe to NUS to
// talk to Vibe Buddy exactly like a serial port.
//
// Service UUID  6e400001-b5a3-f393-e0a9-e50e24dcca9e
// RX char       6e400002-b5a3-f393-e0a9-e50e24dcca9e   (central -> device, WRITE)
// TX char       6e400003-b5a3-f393-e0a9-e50e24dcca9e   (device -> central, NOTIFY)
//
// Phase 1: no pairing/encryption. Anyone nearby can connect; fine for
// bench work and lets nRF Connect poke at us directly. Encryption is a
// phase 2 concern.

void bleInit(const char* deviceName);
bool bleConnected();
uint16_t bleMtu();                 // negotiated ATT MTU, 23 until upgraded

// PHY negotiation state. On every new connection we request 2M PHY both
// directions; the link isn't considered "ready" for audio until we see
// the PHY_UPDATE_COMPLETE event. If the peer refuses 2M we fail loudly
// in phase 1 (no 8kHz fallback) so problems surface rather than hide.
const char* blePhy();              // "1M" | "2M" | "Coded" | "?"
bool bleLinkReady();                // connected AND 2M PHY negotiated
bool bleLinkFailed();               // PHY negotiation came back non-2M

size_t bleAvailable();              // bytes waiting in RX ring
int bleRead();                      // -1 if empty
size_t bleWrite(const uint8_t* data, size_t len);
