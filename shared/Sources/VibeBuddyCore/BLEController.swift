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
    public static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let rxChar     = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let txChar     = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    public static let namePrefix = "VibeBuddy-"

    // Re-entrancy surface to the rest of the app
    private weak var state: AppState?
    public let audio: AudioStreamer

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var jsonBuffer = Data()

    public init(textHandler: any TextHandler) {
        self.audio = AudioStreamer(textHandler: textHandler)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func bind(state: AppState) {
        self.state = state
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
        central.scanForPeripherals(withServices: [Self.nusService], options: nil)
        NSLog("[ble] scanning for services=%@", Self.nusService.uuidString)
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
        guard let name = peripheral.name, name.hasPrefix(Self.namePrefix) else { return }
        Task { @MainActor in
            NSLog("[ble] discovered %@ rssi=%d", name, RSSI.intValue)
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state?.link = .connecting(name)
            central.connect(peripheral, options: nil)
        }
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
        let pcm = data.subdata(in: 6 ..< (6 + len))
        audio.onAudioFrame(seq: seq, pcm: pcm)
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
