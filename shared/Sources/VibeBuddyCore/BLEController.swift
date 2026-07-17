import Foundation
import CoreBluetooth
import Combine

// BLEController owns the CBCentralManager and turns the raw notify stream
// into (a) structured events on AppState and (b) audio frames for the
// AudioStreamer. Frame parsing mirrors tools/ble_audio_dump.py exactly so
// a session that works in Python also works here.
//
// The host app passes in a TextHandler at construction time so the same
// CoreBluetooth + audio stack can drive either macOS keystroke injection
// or iOS pasteboard staging without any platform conditionals here.
@MainActor
public final class BLEController: NSObject, ObservableObject {
    // Nordic UART Service. UUIDs are string-compared by CoreBluetooth; the
    // canonical form is lowercase in Apple's tooling.
    // Read from CoreBluetooth's nonisolated delegate callbacks. CBUUID
    // is documented as immutable but Apple hasn't annotated it
    // Sendable, so under Swift 6 strict concurrency we have to opt in
    // explicitly with `nonisolated(unsafe)` — safe in practice (these
    // are `let` value-typed UUIDs, never mutated). namePrefix is a
    // String literal so plain `nonisolated` is enough.
    nonisolated(unsafe) public static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) public static let rxChar     = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) public static let txChar     = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    nonisolated public static let namePrefix = "VibeBuddy-"

    // Re-entrancy surface to the rest of the app
    private weak var state: AppState?
    public let audio: AudioStreamer

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var jsonBuffer = Data()

    // Authoritative copy; AppState.pairedDeviceIDs mirrors it for the UI.
    // Empty = unpaired = connect to the first Vibe Buddy we see.
    private var pairedDeviceIDs: [String] = []

    // True while a pairing sheet is open. Changes two things: we scan
    // with allowDuplicates (so RSSI keeps refreshing) and we don't
    // stopScan() on connect.
    private var discovering = false

    public init(textHandler: any TextHandler) {
        self.audio = AudioStreamer(textHandler: textHandler)
        self.pairedDeviceIDs = PairedDeviceStore.load()
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        NSLog("[ble] paired devices: %@",
              pairedDeviceIDs.isEmpty ? "(none — will connect to first seen)"
                                      : pairedDeviceIDs.joined(separator: ","))
    }

    // MARK: pairing

    // "VibeBuddy-C3D8" -> "C3D8". nil for anything not ours.
    nonisolated public static func deviceID(fromName name: String) -> String? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let id = String(name.dropFirst(namePrefix.count))
        return id.isEmpty ? nil : id.uppercased()
    }

    private func shouldConnect(to name: String) -> Bool {
        guard let id = Self.deviceID(fromName: name) else { return false }
        // Unpaired: preserve the legacy first-seen behavior so existing
        // installs keep working after an upgrade.
        guard !pairedDeviceIDs.isEmpty else { return true }
        return pairedDeviceIDs.contains(id)
    }

    // Called by the pairing UI when its sheet appears.
    public func startDiscovery() {
        discovering = true
        state?.discovering = true
        state?.discoveredDevices = []
        guard central.state == .poweredOn else { return }
        // allowDuplicates so RSSI updates while the sheet is open. This
        // is more expensive than a plain scan, which is exactly why it's
        // scoped to the sheet's lifetime rather than always-on.
        central.scanForPeripherals(
            withServices: [Self.nusService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        NSLog("[ble] discovery scan started")
    }

    public func stopDiscovery() {
        discovering = false
        state?.discovering = false
        guard central.state == .poweredOn else { return }
        central.stopScan()
        // If the sheet's pairing changes stranded us on a device that's
        // no longer paired, drop it; otherwise resume the normal scan
        // only when we have nothing connected.
        if let p = peripheral, let name = p.name, !shouldConnect(to: name) {
            NSLog("[ble] %@ no longer paired — disconnecting", name)
            central.cancelPeripheralConnection(p)   // triggers beginScan via delegate
        } else if peripheral == nil {
            beginScan()
        }
        NSLog("[ble] discovery scan stopped")
    }

    public func pair(deviceID id: String) {
        var ids = pairedDeviceIDs
        ids.append(id)
        applyPairing(PairedDeviceStore.normalize(ids))
    }

    public func unpair(deviceID id: String) {
        let target = id.uppercased()
        applyPairing(pairedDeviceIDs.filter { $0 != target })
    }

    private func applyPairing(_ ids: [String]) {
        pairedDeviceIDs = ids
        PairedDeviceStore.save(ids)
        state?.pairedDeviceIDs = ids
        NSLog("[ble] paired devices now: %@",
              ids.isEmpty ? "(none)" : ids.joined(separator: ","))
        // Don't tear down a live link here — stopDiscovery() reconciles
        // once the user is done editing. Unpairing the connected device
        // mid-sheet and re-pairing it shouldn't cost a reconnect.
    }

    public func bind(state: AppState) {
        self.state = state
        state.pairedDeviceIDs = pairedDeviceIDs
        audio.onSessionUpdate = { [weak state] update in
            state?.session = update
        }
        audio.onDumpPath = { [weak state] path in
            state?.lastDumpPath = path
        }
        audio.onSessionEnded = { [weak state] in
            state?.totalSessions += 1
        }
        audio.onASRStatus = { [weak state] s in
            state?.sttStatus = s
        }
        audio.onPartialText = { [weak state] t in
            state?.partialText = t
        }
        audio.onFinalText = { [weak state] t in
            state?.finalText = t
            state?.partialText = ""
        }
        audio.onASRError = { [weak state] msg in
            state?.asrError = msg
        }
        audio.onPermissionRequired = { [weak state] in
            state?.accessibilityTrusted = false
        }

        // Surface boot-time config and permission state to the UI.
        state.configMissing = (Config.load() == nil)
        state.accessibilityTrusted = audio.textHandler.checkPermission()
    }

    // MARK: upstream control (host -> device)

    public func write(_ data: Data) {
        guard let p = peripheral, let rx = rxCharacteristic else { return }
        p.writeValue(data, for: rx, type: .withoutResponse)
    }

    // MARK: scan lifecycle

    private func beginScan() {
        guard central.state == .poweredOn else { return }
        peripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        jsonBuffer.removeAll()
        state?.link = .scanning
        state?.linkParams = AppState.LinkParams()
        // Filter by service UUID at scan time so we only see actual Vibe
        // Buddy advertisements (not every BLE thing on the street).
        //
        // Keep allowDuplicates on if a pairing sheet is open: a
        // disconnect re-enters here, and a plain rescan would silently
        // replace the discovery scan and freeze the sheet's RSSI values.
        let options: [String: Any]? = discovering
            ? [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            : nil
        central.scanForPeripherals(withServices: [Self.nusService], options: options)
        NSLog("[ble] scanning for services=%@%@", Self.nusService.uuidString,
              discovering ? " (+duplicates, pairing sheet open)" : "")
    }
}

extension BLEController: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.state?.bluetoothPoweredOn = (central.state == .poweredOn)
            switch central.state {
            case .poweredOn:   self.beginScan()
            case .poweredOff:  self.state?.link = .failed("Bluetooth off")
            case .unauthorized: self.state?.link = .failed("Bluetooth permission denied")
            default:           self.state?.link = .idle
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        guard let name = peripheral.name, let id = Self.deviceID(fromName: name) else { return }
        Task { @MainActor in
            // Feed the pairing sheet regardless of whether this device
            // is paired — the whole point of that list is to show the
            // ones you haven't paired yet.
            if self.discovering {
                self.upsertDiscovered(id: id, name: name, rssi: RSSI.intValue)
            }

            // Connect path. Only one link at a time: if we already have
            // a peripheral (connecting or connected) leave it alone.
            guard self.peripheral == nil else { return }
            guard self.shouldConnect(to: name) else { return }

            NSLog("[ble] connecting to %@ rssi=%d", name, RSSI.intValue)
            // Keep the radio scanning while a pairing sheet is up, so
            // its list doesn't freeze the moment we latch onto a device.
            if !self.discovering { central.stopScan() }
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state?.link = .connecting(name)
            central.connect(peripheral, options: nil)
        }
    }

    @MainActor
    private func upsertDiscovered(id: String, name: String, rssi: Int) {
        guard let state else { return }
        if let i = state.discoveredDevices.firstIndex(where: { $0.id == id }) {
            state.discoveredDevices[i].rssi = rssi
        } else {
            state.discoveredDevices.append(
                AppState.DiscoveredDevice(id: id, name: name, rssi: rssi)
            )
        }
        // Strongest first — the one in your hand should be at the top.
        state.discoveredDevices.sort { $0.rssi > $1.rssi }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            let name = peripheral.name ?? "?"
            NSLog("[ble] connected to %@", name)
            self.state?.link = .connected(name)
            // Record MTU before service discovery because it's known as
            // soon as the link is up; the device-side PHY is surfaced via
            // the {"type":"link"} JSON event we'll see on subscription.
            let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
            self.state?.linkParams.mtu = mtu
            peripheral.discoverServices([Self.nusService])
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            NSLog("[ble] connect failed: %@", error?.localizedDescription ?? "unknown")
            self.state?.link = .failed(error?.localizedDescription ?? "connect failed")
            self.beginScan()
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            NSLog("[ble] disconnected: %@", error?.localizedDescription ?? "clean")
            self.jsonBuffer.removeAll()
            self.audio.cancelSession()
            self.state?.link = .scanning
            self.beginScan()
        }
    }
}

extension BLEController: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.nusService }) else { return }
        peripheral.discoverCharacteristics([Self.rxChar, Self.txChar], for: svc)
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                if c.uuid == Self.rxChar { self.rxCharacteristic = c }
                if c.uuid == Self.txChar {
                    self.txCharacteristic = c
                    peripheral.setNotifyValue(true, for: c)
                    NSLog("[ble] subscribed to TX")
                }
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txChar, let data = characteristic.value else { return }
        Task { @MainActor in
            self.dispatch(data)
        }
    }

    // Dispatch a single notify payload. Firmware ensures one notify is
    // either pure JSON (terminated/continued with \n) or a pure audio
    // frame starting with 0xFF 0xAA -- the two never mix within a PDU.
    private func dispatch(_ data: Data) {
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xAA {
            handleAudioFrame(data)
        } else {
            handleJSONBytes(data)
        }
    }

    private func handleAudioFrame(_ data: Data) {
        guard data.count >= 6 else {
            NSLog("[ble] short audio frame: %d", data.count)
            return
        }
        let seq = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let len = Int(UInt16(data[4]) | (UInt16(data[5]) << 8))
        guard data.count >= 6 + len else {
            NSLog("[ble] truncated audio frame: header=%d got=%d", len, data.count - 6)
            return
        }
        // Payload is PCM or one Opus packet — the frame header is codec
        // agnostic, and AudioStreamer already knows which from the
        // audio/start control frame.
        let payload = data.subdata(in: 6 ..< (6 + len))
        audio.onAudioFrame(seq: seq, payload: payload)
    }

    private func handleJSONBytes(_ data: Data) {
        jsonBuffer.append(data)
        while let nl = jsonBuffer.firstIndex(of: 0x0A) {  // '\n'
            let line = jsonBuffer[..<nl]
            jsonBuffer.removeSubrange(...nl)
            guard let str = String(data: line, encoding: .utf8), !str.isEmpty else { continue }
            handleJSONLine(str)
        }
    }

    private func handleJSONLine(_ line: String) {
        state?.lastJSON = line
        NSLog("[json] %@", line)

        // We don't pull in a full JSON parser for these: the firmware
        // emits a small closed set of message shapes and cheap substring
        // matching is plenty. Step 6 will formalize this with Codable.
        if line.contains("\"type\":\"link\"") {
            if let phy = extractString(from: line, key: "phy") { state?.linkParams.phy = phy }
            if let mtu = extractInt(from: line, key: "mtu")    { state?.linkParams.mtu = mtu }
            return
        }
        if line.contains("\"type\":\"audio\"") {
            audio.handleControl(line)
            return
        }
        if line.contains("\"type\":\"edit\"") {
            handleEditLine(line)
            return
        }
        if line.contains("\"type\":\"log\"") {
            // Structured log channel from the device — used for power
            // profiling without a USB cable. Prints under a dedicated tag
            // so it's easy to grep out of the noise.
            if let msg = extractString(from: line, key: "msg") {
                NSLog("[dev] %@", msg)
            }
            return
        }
    }

    private func handleEditLine(_ line: String) {
        guard let action = extractString(from: line, key: "action") else { return }
        NSLog("[edit] %@", action)
        switch action {
        case "newline":   audio.textHandler.sendEnter()
        case "backspace": audio.textHandler.sendBackspaceChar()
        case "clear":     audio.textHandler.clearAll()
        default:          NSLog("[edit] unknown action: %@", action)
        }
    }

    // MARK: tiny string-bashing JSON field extractors

    private func extractString(from line: String, key: String) -> String? {
        guard let range = line.range(of: "\"\(key)\":\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func extractInt(from line: String, key: String) -> Int? {
        guard let range = line.range(of: "\"\(key)\":") else { return nil }
        let rest = line[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }
}
