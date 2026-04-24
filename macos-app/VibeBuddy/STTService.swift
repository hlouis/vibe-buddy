import Foundation

// Doubao Big-Model streaming ASR client.
//
// Binary framing per the official spec:
//   byte 0: [4b protocol_version=1][4b header_size=1 (i.e. 4 bytes)]
//   byte 1: [4b message_type][4b message_type_flags]
//   byte 2: [4b serialization][4b compression]
//   byte 3: reserved 0x00
//
// Then, depending on the message type:
//   client full-request / audio-only:  [4B payload_size BE][gzip(payload)]
//   server response (has positive seq): [4B seq BE][4B payload_size BE][gzip(json)]
//   server error:                      [4B err_code BE][4B err_size BE][UTF8 msg]
//
// We pick bigmodel_async (optimized full-duplex): the server only emits a
// frame when the result actually changes, which gives lower text churn
// through the TextInjector.

// Captures the HTTP upgrade response so we can actually diagnose
// handshake failures (otherwise URLSession surfaces only "bad response
// from the server" with no status code or body).
private final class WSDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    var onOpen: ((String?) -> Void)?
    var onFailHeaders: ((Int, [AnyHashable: Any]) -> Void)?
    var onComplete: ((Error?) -> Void)?

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        onOpen?(proto)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        NSLog("[stt] ws closed code=%d reason=%@", closeCode.rawValue, reasonStr)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Only surface response headers when the handshake actually
        // failed. HTTP 101 with nil error is the normal "upgrade ok,
        // connection has now ended cleanly" path.
        if let http = task.response as? HTTPURLResponse,
           http.statusCode != 101 {
            onFailHeaders?(http.statusCode, http.allHeaderFields)
        }
        onComplete?(error)
    }
}

@MainActor
final class STTService: NSObject {

    enum Status: Equatable {
        case idle
        case connecting
        case streaming
        case closing
        case failed(String)
    }

    // Callbacks fire on the main actor. partialText is the current best
    // cumulative transcript (result_type=full); finalText is the last one
    // delivered when the server sees the end-of-audio marker.
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStatus: ((Status) -> Void)?
    var onError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var delegate: WSDelegate?
    private var active: Bool = false
    private var sampleRate: Int = 16000
    private var seq: Int32 = 1    // per Go demo: starts at 1, negated for last

    // Flip to true to fall back to the plain bigmodel endpoint if the
    // optimized bigmodel_async handshake fails. Resource IDs that are
    // only provisioned for the base service need this.
    private let useAsyncEndpoint: Bool = false

    // MARK: lifecycle

    func startSession(sampleRate: Int) {
        guard !active else { return }
        guard let cfg = Config.load() else {
            let path = Config.configURL().path
            onStatus?(.failed("missing config at \(path)"))
            onError?("no config")
            return
        }

        self.sampleRate = sampleRate
        self.active = true
        onStatus?(.connecting)

        let endpoint = useAsyncEndpoint
            ? "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
            : "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"
        guard let url = URL(string: endpoint) else {
            onStatus?(.failed("bad url"))
            return
        }
        let requestID = UUID().uuidString
        var req = URLRequest(url: url)
        // Two auth schemes exist on this endpoint:
        //   1. X-Api-App-Key + X-Api-Access-Key (Go demo, older doc)
        //   2. single X-Api-Key  (what actually works for our tenant)
        // Send both so either account type authenticates. The unused one
        // is ignored by the server.
        req.setValue(cfg.accessToken, forHTTPHeaderField: "X-Api-Key")
        req.setValue(cfg.appID, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(cfg.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(cfg.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        // Docs say X-Api-Connect-Id but the working Go reference uses
        // X-Api-Request-Id — the server rejects the handshake without it.
        req.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        req.timeoutInterval = 10
        NSLog("[stt] dialing %@ (request-id=%@, resource=%@)",
              endpoint, requestID, cfg.resourceID)

        let wsDelegate = WSDelegate()
        wsDelegate.onOpen = { proto in
            NSLog("[stt] ws handshake OK (proto=%@)", proto ?? "")
        }
        wsDelegate.onFailHeaders = { [weak self] code, headers in
            NSLog("[stt] ws handshake HTTP %d", code)
            for (k, v) in headers {
                NSLog("[stt]   %@: %@", String(describing: k), String(describing: v))
            }
            Task { @MainActor in
                self?.onStatus?(.failed("handshake HTTP \(code)"))
                self?.onError?("HTTP \(code); check logid / credentials / resource_id")
            }
        }
        self.delegate = wsDelegate
        let s = URLSession(configuration: .default, delegate: wsDelegate, delegateQueue: nil)
        let t = s.webSocketTask(with: req)
        self.session = s
        self.task = t

        seq = 1
        t.resume()
        sendFullClientRequest()
        receiveLoop()
        onStatus?(.streaming)
    }

    func pushAudio(_ pcm: Data) {
        guard active, let task else { return }
        guard let gz = Gzip.compress(pcm) else {
            NSLog("[stt] gzip compress failed")
            return
        }
        seq += 1
        let thisSeq = seq
        let frame = audioFrame(payload: gz, seq: thisSeq, isLast: false)
        task.send(.data(frame)) { err in
            if let err = err {
                NSLog("[stt] audio send err (seq=%d): %@", thisSeq, String(describing: err))
            }
        }
    }

    func endSession() {
        guard active, let task else { return }
        onStatus?(.closing)
        // Per the Go reference: last audio frame uses NEG_WITH_SEQUENCE
        // (flag 0x3) and a NEGATIVE sequence number. Empty payload is OK;
        // server keys off the flag and seq sign to finalize.
        let gz = Gzip.compress(Data()) ?? Data()
        seq += 1
        let lastSeq = -seq
        let frame = audioFrame(payload: gz, seq: lastSeq, isLast: true)
        NSLog("[stt] sending last audio frame seq=%d", lastSeq)
        task.send(.data(frame)) { [weak self] err in
            if let err = err {
                NSLog("[stt] final send err: %@", String(describing: err))
                Task { @MainActor in self?.teardown() }
            }
        }
    }

    func cancel() {
        teardown()
        onStatus?(.idle)
    }

    private func teardown() {
        active = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: client -> server frames

    private func sendFullClientRequest() {
        let json: [String: Any] = [
            "user": [
                "uid": "vibe-buddy-mac"
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": sampleRate,
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "model_name": "bigmodel",
                "show_utterances": true,
                "enable_punc": true,
                "enable_itn": true,
                "end_window_size": 800,
                "result_type": "full"
            ]
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let gz = Gzip.compress(jsonData) else {
            onStatus?(.failed("config frame encode failed"))
            return
        }
        // Per the Go reference, EVERY client frame (full_client_request
        // and audio_only) carries a 4-byte sequence number right after the
        // 4-byte header and uses POS_SEQUENCE (flag 0x1). The docs' sample
        // frame layout omits the seq, which is misleading.
        var frame = Data()
        frame.append(contentsOf: Proto.headerBytes(
            type: .fullClientRequest,
            flags: .positiveSeq,
            ser: .json,
            cmpr: .gzip
        ))
        appendInt32BE(seq, to: &frame)
        appendUInt32BE(UInt32(gz.count), to: &frame)
        frame.append(gz)

        task?.send(.data(frame)) { [weak self] err in
            if let err = err {
                NSLog("[stt] config send err: %@", String(describing: err))
                Task { @MainActor in self?.onStatus?(.failed(err.localizedDescription)) }
            } else {
                NSLog("[stt] sent full_client_request (%d bytes) seq=1", frame.count)
            }
        }
    }

    private func audioFrame(payload: Data, seq: Int32, isLast: Bool) -> Data {
        var frame = Data()
        frame.append(contentsOf: Proto.headerBytes(
            type: .audioOnlyRequest,
            flags: isLast ? .negativeSeq : .positiveSeq,
            ser: .raw,
            cmpr: .gzip
        ))
        appendInt32BE(seq, to: &frame)
        appendUInt32BE(UInt32(payload.count), to: &frame)
        frame.append(payload)
        return frame
    }

    // MARK: server -> client

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.data(let data)):
                    self.handleFrame(data)
                case .success(.string(let s)):
                    NSLog("[stt] unexpected text frame: %@", s)
                case .failure(let err):
                    let nsErr = err as NSError
                    // A clean close after endSession() surfaces as an
                    // NSURLErrorCancelled; that's expected, not a failure.
                    if nsErr.code != NSURLErrorCancelled {
                        NSLog("[stt] recv err: %@", err.localizedDescription)
                        self.onStatus?(.failed(err.localizedDescription))
                        self.onError?(err.localizedDescription)
                    }
                    self.teardown()
                    return
                @unknown default:
                    break
                }
                if self.active { self.receiveLoop() }
            }
        }
    }

    private func handleFrame(_ data: Data) {
        guard data.count >= 4 else { return }
        let ver = (data[0] >> 4) & 0x0F
        let headerSize = Int(data[0] & 0x0F) * 4
        let msgType = (data[1] >> 4) & 0x0F
        let flags = data[1] & 0x0F
        let cmpr = data[2] & 0x0F
        guard ver == 1, headerSize >= 4 else {
            NSLog("[stt] bad header ver=%u hsize=%d", ver, headerSize)
            return
        }

        var offset = headerSize

        if msgType == Proto.MessageType.errorResponse.rawValue {
            guard data.count >= offset + 8 else { return }
            let code = readUInt32BE(data, at: offset); offset += 4
            let size = readUInt32BE(data, at: offset); offset += 4
            let end = offset + Int(size)
            guard data.count >= end else { return }
            let body = data.subdata(in: offset..<end)
            let msg: String
            if cmpr == Proto.Compression.gzip.rawValue,
               let inflated = Gzip.decompress(body) {
                msg = String(data: inflated, encoding: .utf8) ?? "?"
            } else {
                msg = String(data: body, encoding: .utf8) ?? "?"
            }
            NSLog("[stt] server error code=%u msg=%@", code, msg)
            onError?("code=\(code) \(msg)")
            onStatus?(.failed("code=\(code)"))
            teardown()
            return
        }

        guard msgType == Proto.MessageType.fullServerResponse.rawValue else {
            NSLog("[stt] unhandled msg type: %u", msgType)
            return
        }

        // bit 0 of flags => sequence follows header; bit 1 => last packet.
        // Mirror the Go reference's bitwise decoding so we correctly handle
        // any combination the server might use.
        var respSeq: Int32 = 0
        if flags & 0x01 != 0 {
            guard data.count >= offset + 4 else { return }
            respSeq = Int32(bitPattern: readUInt32BE(data, at: offset))
            offset += 4
        }
        let isFinal = (flags & 0x02) != 0

        guard data.count >= offset + 4 else { return }
        let payloadSize = Int(readUInt32BE(data, at: offset)); offset += 4
        guard data.count >= offset + payloadSize else { return }
        let payload = data.subdata(in: offset ..< offset + payloadSize)

        let json: Data
        if cmpr == Proto.Compression.gzip.rawValue {
            guard let inflated = Gzip.decompress(payload) else {
                NSLog("[stt] gzip decompress of %d bytes failed", payload.count)
                return
            }
            json = inflated
        } else {
            json = payload
        }

        parseResponse(json: json, seq: respSeq, isFinal: isFinal)
    }

    private func parseResponse(json: Data, seq: Int32, isFinal: Bool) {
        struct R: Decodable {
            struct Result: Decodable {
                var text: String?
            }
            var result: Result?
        }
        let text: String
        do {
            let r = try JSONDecoder().decode(R.self, from: json)
            text = r.result?.text ?? ""
        } catch {
            // Some frames (e.g. initial config ack) come back without a
            // result field. Just log and move on.
            if let s = String(data: json, encoding: .utf8) {
                NSLog("[stt] decode skip seq=%d: %@", seq, s.prefix(160) as CVarArg)
            }
            return
        }

        if isFinal {
            NSLog("[stt] FINAL seq=%d text=%@", seq, text)
            onFinal?(text)
            // Stop accepting new pushes but don't tear down yet — the
            // server closes the socket after this frame, and tearing down
            // eagerly while URLSession has writes in flight produces the
            // nw_flow "socket not connected" warnings.
            active = false
            onStatus?(.idle)
        } else {
            NSLog("[stt] partial seq=%d text=%@", seq, text)
            onPartial?(text)
        }
    }

    // MARK: helpers

    private func appendUInt32BE(_ v: UInt32, to data: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendInt32BE(_ v: Int32, to data: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

private enum Proto {
    static let protocolVersion: UInt8 = 0x1
    static let headerSizeUnits: UInt8 = 0x1   // × 4 = 4 bytes

    enum MessageType: UInt8 {
        case fullClientRequest = 0x1
        case audioOnlyRequest = 0x2
        case fullServerResponse = 0x9
        case errorResponse = 0xF
    }

    enum Flags: UInt8 {
        case none = 0x0
        case positiveSeq = 0x1
        case lastPacket = 0x2
        case negativeSeq = 0x3
    }

    enum Serialization: UInt8 {
        case raw = 0x0
        case json = 0x1
    }

    enum Compression: UInt8 {
        case none = 0x0
        case gzip = 0x1
    }

    static func headerBytes(type: MessageType, flags: Flags,
                            ser: Serialization, cmpr: Compression) -> [UInt8] {
        return [
            (protocolVersion << 4) | headerSizeUnits,
            (type.rawValue << 4) | flags.rawValue,
            (ser.rawValue << 4) | cmpr.rawValue,
            0x00
        ]
    }
}
