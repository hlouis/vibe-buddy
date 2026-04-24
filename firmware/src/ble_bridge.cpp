#include "ble_bridge.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Arduino.h>
#include <esp_gap_ble_api.h>
#include <string.h>

#define NUS_SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define NUS_RX_UUID      "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define NUS_TX_UUID      "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

static const size_t RX_CAP = 2048;
static uint8_t  rxBuf[RX_CAP];
static volatile size_t rxHead = 0;
static volatile size_t rxTail = 0;

static BLEServer*         server = nullptr;
static BLECharacteristic* txChar = nullptr;
static BLECharacteristic* rxChar = nullptr;
static volatile bool      connected = false;
static volatile uint16_t  mtu = 23;
static volatile uint8_t   txPhy = 1;    // 1 = 1M, 2 = 2M, 3 = coded
static volatile uint8_t   rxPhy = 1;
static volatile bool      phyEventSeen = false;
static volatile bool      phyFailed = false;
static esp_bd_addr_t      peerAddr = {0};
static volatile bool      peerAddrValid = false;

static void rxPush(const uint8_t* p, size_t n) {
  for (size_t i = 0; i < n; i++) {
    size_t next = (rxHead + 1) % RX_CAP;
    if (next == rxTail) return;
    rxBuf[rxHead] = p[i];
    rxHead = next;
  }
}

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    std::string v = c->getValue();
    if (!v.empty()) rxPush((const uint8_t*)v.data(), v.size());
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  // The param version fires first with the connection event; we grab the
  // remote BDA here so we can target per-connection PHY preference.
  void onConnect(BLEServer*, esp_ble_gatts_cb_param_t* param) override {
    connected = true;
    phyEventSeen = false;
    phyFailed = false;
    txPhy = rxPhy = 1;
    memcpy(peerAddr, param->connect.remote_bda, sizeof(esp_bd_addr_t));
    peerAddrValid = true;
    Serial.println("[ble] connected");

    // Ask for 2M both directions. all_phys=0 means 'use the masks'; we set
    // only the 2M bit, so 1M is effectively forbidden as a preference. The
    // stack still falls back to 1M if the peer rejects -- we detect that
    // via PHY_UPDATE_COMPLETE below.
    // Note: IDF API has a typo -- "prefered" (single r). Keeping the misspell.
    esp_err_t r = esp_ble_gap_set_prefered_phy(
      peerAddr,
      0,
      ESP_BLE_GAP_PHY_2M_PREF_MASK,
      ESP_BLE_GAP_PHY_2M_PREF_MASK,
      ESP_BLE_GAP_PHY_OPTIONS_NO_PREF
    );
    Serial.printf("[ble] set_preferred_phy -> %d\n", (int)r);

    // Data Length Extension. Without this the link-layer PDU stays at
    // 27 bytes, which shreds every 500-byte ATT notify into ~20 LL PDUs
    // and starves the throughput even on 2M PHY. 251 is the BT spec max.
    esp_err_t d = esp_ble_gap_set_pkt_data_len(peerAddr, 251);
    Serial.printf("[ble] set_pkt_data_len(251) -> %d\n", (int)d);

    // Ask iOS for a tight connection interval. iOS picks 15-30ms by
    // default; audio needs events frequent enough to drain notify queue.
    // 0x06 * 1.25ms = 7.5ms min, 0x0C * 1.25ms = 15ms max.
    esp_ble_conn_update_params_t cp = {};
    memcpy(cp.bda, peerAddr, sizeof(esp_bd_addr_t));
    cp.min_int = 0x06;
    cp.max_int = 0x0C;
    cp.latency = 0;
    cp.timeout = 400;   // 4 s supervision timeout
    esp_err_t c = esp_ble_gap_update_conn_params(&cp);
    Serial.printf("[ble] update_conn_params 7.5-15ms -> %d\n", (int)c);
  }
  void onDisconnect(BLEServer*) override {
    connected = false;
    mtu = 23;
    txPhy = rxPhy = 1;
    phyEventSeen = false;
    phyFailed = false;
    peerAddrValid = false;
    Serial.println("[ble] disconnected");
    BLEDevice::startAdvertising();
  }
  void onMtuChanged(BLEServer*, esp_ble_gatts_cb_param_t* param) override {
    mtu = param->mtu.mtu;
    Serial.printf("[ble] mtu=%u\n", mtu);
  }
};

// BLEDevice runs its own GAP handler; we chain ours to observe the events
// it doesn't expose (PHY_UPDATE_COMPLETE is not surfaced by BLEServer).
static void customGapHandler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t* param) {
  switch (event) {
    case ESP_GAP_BLE_SET_PKT_LENGTH_COMPLETE_EVT: {
      auto& p = param->pkt_data_lenth_cmpl;
      Serial.printf("[ble] data-length: rx=%u tx=%u status=%d\n",
                    (unsigned)p.params.rx_len, (unsigned)p.params.tx_len,
                    (int)p.status);
      break;
    }
    case ESP_GAP_BLE_UPDATE_CONN_PARAMS_EVT: {
      auto& p = param->update_conn_params;
      Serial.printf("[ble] conn-params: int=%u lat=%u to=%u status=%d\n",
                    (unsigned)p.conn_int, (unsigned)p.latency,
                    (unsigned)p.timeout, (int)p.status);
      break;
    }
    case ESP_GAP_BLE_PHY_UPDATE_COMPLETE_EVT: {
      auto& p = param->phy_update;
      phyEventSeen = true;
      if (p.status == ESP_BT_STATUS_SUCCESS) {
        txPhy = p.tx_phy;
        rxPhy = p.rx_phy;
        Serial.printf("[ble] phy update: tx=%u rx=%u\n", (unsigned)p.tx_phy, (unsigned)p.rx_phy);
        if (p.tx_phy != 2 || p.rx_phy != 2) {
          phyFailed = true;
          Serial.println("[ble] PHY != 2M on one or both directions -- audio disabled");
        }
      } else {
        Serial.printf("[ble] phy update FAILED status=%d\n", (int)p.status);
        phyFailed = true;
      }
      break;
    }
    default: break;
  }
}

void bleInit(const char* deviceName) {
  BLEDevice::init(deviceName);
  BLEDevice::setMTU(517);

  // Default preference in case a peer connects before our per-connection
  // esp_ble_gap_set_preferred_phy() call lands.
  esp_err_t r = esp_ble_gap_set_prefered_default_phy(
    ESP_BLE_GAP_PHY_2M_PREF_MASK,
    ESP_BLE_GAP_PHY_2M_PREF_MASK
  );
  Serial.printf("[ble] default_phy=2M -> %d\n", (int)r);

  BLEDevice::setCustomGapHandler(customGapHandler);

  server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* svc = server->createService(NUS_SERVICE_UUID);

  txChar = svc->createCharacteristic(
    NUS_TX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  txChar->addDescriptor(new BLE2902());

  rxChar = svc->createCharacteristic(
    NUS_RX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  rxChar->setCallbacks(new RxCallbacks());

  svc->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(NUS_SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();
  Serial.printf("[ble] advertising as '%s'\n", deviceName);
}

bool bleConnected() { return connected; }
uint16_t bleMtu()   { return mtu; }

const char* blePhy() {
  // Report the slower of the two directions -- audio throughput is gated
  // by whichever is lower.
  uint8_t p = txPhy < rxPhy ? txPhy : rxPhy;
  if (!phyEventSeen) return "?";
  switch (p) {
    case 1: return "1M";
    case 2: return "2M";
    case 3: return "Coded";
    default: return "?";
  }
}

bool bleLinkReady() {
  return connected && phyEventSeen && !phyFailed && txPhy == 2 && rxPhy == 2;
}

bool bleLinkFailed() {
  return connected && phyEventSeen && phyFailed;
}

size_t bleAvailable() {
  return (rxHead + RX_CAP - rxTail) % RX_CAP;
}

int bleRead() {
  if (rxHead == rxTail) return -1;
  int b = rxBuf[rxTail];
  rxTail = (rxTail + 1) % RX_CAP;
  return b;
}

size_t bleWrite(const uint8_t* data, size_t len) {
  if (!connected || !txChar) return 0;
  size_t chunk = mtu > 3 ? (size_t)(mtu - 3) : 20;
  // Arduino-ESP32 BLEDevice::setMTU(517) gives us headroom. Raising the
  // cap means fewer notifies per second for audio (half the rate at 500
  // vs 244), which matters when the link is loaded.
  if (chunk > 500) chunk = 500;
  size_t sent = 0;
  while (sent < len) {
    size_t n = len - sent;
    if (n > chunk) n = chunk;
    txChar->setValue((uint8_t*)(data + sent), n);
    txChar->notify();
    sent += n;
    // Let the BLE stack transmit before queueing more. 1 ms is enough on
    // 2M PHY; the original 4 ms would starve the audio pipeline.
    delay(1);
  }
  return sent;
}
