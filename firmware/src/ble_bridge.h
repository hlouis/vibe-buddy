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

// PHY negotiation state. We request 2M on every new connection because
// it halves airtime for free, but losing it is not fatal: on-device Opus
// needs ~20 kbps and 1M carries that easily. "Ready" therefore means the
// PHY_UPDATE_COMPLETE event has landed and the link params have settled,
// whatever PHY we ended up on. What audio actually needs is a big enough
// MTU — see recorderLinkOk().
const char* blePhy();              // "1M" | "2M" | "Coded" | "?"
bool bleLinkReady();                // connected AND PHY negotiation settled

size_t bleAvailable();              // bytes waiting in RX ring
int bleRead();                      // -1 if empty
size_t bleWrite(const uint8_t* data, size_t len);
