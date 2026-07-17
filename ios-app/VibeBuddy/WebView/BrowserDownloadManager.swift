import Foundation
import Observation
import WebKit

// In-browser file download manager. Deliberately the "笨但稳" version:
//
//   1. We don't use WebKit's WKDownload pipeline. The iOS 26 SwiftUI
//      WebPage API exposes navigation policy decisions (NavigationDeciding)
//      but does not surface didBecomeDownload / WKDownload back to the
//      app — there is no public hook to receive the WKDownload object
//      created by returning .download from decidePolicy(for:NavigationResponse).
//      So we cancel the navigation and re-fetch the URL ourselves.
//
//   2. The re-fetch is a vanilla URLSession.download(for:) — no progress
//      delegate, no resumeData, no background URLSession. User said the
//      files won't be large; keep the moving parts to a minimum.
//
//   3. On success we keep the file in the temporary directory and hand
//      the URL to the UI, which presents a UIActivityViewController so
//      the user can save into Files, AirDrop it, mail it, etc.
//
// Known limitations (acceptable for v1):
//   • blob: URLs (common for client-side "Export as JSON" buttons in SPAs)
//     can't be fetched by URLSession — we record an error and the user
//     sees a "无法下载 blob: 链接" line in the status row.
//   • Sites that gate downloads behind cookie-auth will work because we
//     copy cookies from the WebPage's WKWebsiteDataStore before firing
//     the request, but anything relying on other browser state
//     (sessionStorage tokens, headers set by JS) will 401.
//   • Cancellation is best-effort — we cancel the URLSession task but
//     don't surface a cancel button in the UI yet.
@Observable
@MainActor
final class BrowserDownloadManager {

    enum State: Equatable {
        case downloading
        case finished(URL)          // local temp file URL
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let url: URL
        var filename: String
        var state: State
        var startedAt: Date
    }

    // Newest-first. Capped at 20 to avoid unbounded growth — older
    // entries fall off the end. The UI only ever shows the head.
    private(set) var items: [Item] = []

    // Set non-nil when a download finishes — BrowserTabView observes
    // this and pops a share sheet. UI clears it on dismiss.
    var pendingShare: URL?

    // Simple short-window dedup for the inline-data path. SPAs that
    // wire both an onclick handler AND call .click() themselves can
    // double-fire; without this we'd save two copies. Key is
    // "filename|size" — collisions across genuinely different files
    // are vanishingly unlikely in this app's actual usage.
    @ObservationIgnored private var recentInlineKeys: [(key: String, at: Date)] = []
    @ObservationIgnored private let inlineDedupWindow: TimeInterval = 1.5

    // Convenience accessor for the status row.
    var activeCount: Int {
        items.reduce(0) { $0 + ($1.state == .downloading ? 1 : 0) }
    }

    var latest: Item? { items.first }

    // Public entry point called by the navigation decider when it
    // intercepts a download-intent navigation. We copy the cookies the
    // WebPage has accumulated for this host so authenticated downloads
    // work the same way they would inside the WebView.
    // Requests we must not rebuild as a plain GET, keyed by URL. Only
    // non-GET navigations land here: those are the ones where re-issuing
    // `URLRequest(url:)` would change what the server is being asked for.
    //
    // The response-phase hook is the reason this exists at all. It's the
    // one that catches `Content-Disposition: attachment`, but a
    // URLResponse carries no method or body — so a POST export (submit
    // form -> server builds the report -> attachment) would be re-fetched
    // as a GET, and the 405 or login-page HTML that comes back gets saved
    // under the attachment's filename. The action phase, which does see
    // the full request, stashes it here so the response phase can recover
    // it moments later.
    private var pendingRequests: [URL: URLRequest] = [:]
    private static let maxPendingRequests = 8

    func rememberRequest(_ req: URLRequest) {
        guard let url = req.url,
              let method = req.httpMethod, method.uppercased() != "GET" else { return }
        // Bounded: navigations are sequential and we only keep the
        // non-GET ones, but a page that POSTs in a loop must not grow
        // this without limit.
        if pendingRequests.count >= Self.maxPendingRequests {
            pendingRequests.removeAll()
        }
        pendingRequests[url] = req
    }

    func takeRememberedRequest(for url: URL) -> URLRequest? {
        pendingRequests.removeValue(forKey: url)
    }

    func start(url: URL,
               suggestedFilename: String?,
               cookies: [HTTPCookie],
               originalRequest: URLRequest? = nil) {
        // blob: URLs aren't fetchable by URLSession. Surface a clear
        // error rather than silently failing — at least the user knows
        // *why* it didn't work and can right-click → copy link in
        // desktop Safari as a workaround.
        guard url.scheme != "blob" else {
            appendFailed(url: url,
                         filename: suggestedFilename ?? "download",
                         reason: "无法下载 blob: 链接（站点用客户端生成的文件）")
            return
        }

        let name = Self.resolveFilename(url: url, suggested: suggestedFilename)
        let item = Item(id: UUID(),
                        url: url,
                        filename: name,
                        state: .downloading,
                        startedAt: Date())
        prepend(item)

        // Attach matching cookies as a Cookie header. We could also
        // configure URLSessionConfiguration.httpCookieStorage with a
        // custom HTTPCookieStorage, but a one-shot header is simpler
        // and avoids polluting any shared cookie jar.
        // Start from the navigation's own request when we have one, so a
        // POST export is re-issued as the same POST with the same body
        // rather than silently degraded to a GET.
        var req = originalRequest ?? URLRequest(url: url)
        req.url = url
        let matched = cookies.filter { Self.cookieMatches(cookie: $0, url: url) }
        if !matched.isEmpty {
            let header = HTTPCookie.requestHeaderFields(with: matched)
            for (k, v) in header { req.setValue(v, forHTTPHeaderField: k) }
        }
        // Some servers serve a different body without an Accept header.
        // Pretend to be a generic browser; "*/*" is the most permissive.
        if req.value(forHTTPHeaderField: "Accept") == nil {
            req.setValue("*/*", forHTTPHeaderField: "Accept")
        }

        let id = item.id
        Task { [weak self] in
            await self?.run(request: req, itemId: id)
        }
    }

    // Inline-data path: bytes already live in JS land (page-generated
    // blob from a Web SPA — Excel exports, CSV exports, "save current
    // canvas as PNG", etc.) and the JS hook in InjectionScript shipped
    // them across as a `data:<mime>;base64,<...>` URL.
    //
    // We deliberately don't reuse the URLSession path — there's no
    // URLRequest to make, and going through a `data:` URL via
    // URLSession would just round-trip the same bytes. Decode straight
    // into a temp file and trigger the same share-sheet pendingShare
    // hand-off used by the network-download path.
    func startFromInlineData(dataUrl: String,
                             filename: String,
                             mime: String,
                             size: Int) {
        // Dedup: collapse rapid double-fires from SPAs that both
        // onClick-handle and .click()-trigger their <a>.
        let key = "\(filename)|\(size)"
        let now = Date()
        recentInlineKeys.removeAll { now.timeIntervalSince($0.at) > inlineDedupWindow }
        if recentInlineKeys.contains(where: { $0.key == key }) { return }
        recentInlineKeys.append((key, now))

        let resolvedName = Self.resolveInlineFilename(filename: filename, mime: mime)
        let item = Item(id: UUID(),
                        url: URL(string: "about:blob")!,
                        filename: resolvedName,
                        state: .downloading,
                        startedAt: now)
        prepend(item)

        guard let bytes = Self.decodeBase64DataURL(dataUrl) else {
            updateState(id: item.id, to: .failed("无法解析 base64 数据"))
            return
        }

        let dst = uniqueTempURL(filename: resolvedName)
        do {
            try bytes.write(to: dst, options: .atomic)
            updateState(id: item.id, to: .finished(dst))
            pendingShare = dst
        } catch {
            updateState(id: item.id, to: .failed(error.localizedDescription))
        }
    }

    // JS-side error path: hook tried to fetch the blob and failed (or
    // refused — e.g. size > MAX_BYTES). Surface it in the same items
    // list so the user knows something happened.
    func appendFailedInline(filename: String, reason: String) {
        let item = Item(id: UUID(),
                        url: URL(string: "about:blob")!,
                        filename: filename,
                        state: .failed(reason),
                        startedAt: Date())
        prepend(item)
    }

    // MARK: - private

    private func run(request: URLRequest, itemId: UUID) async {
        do {
            let (tmpURL, response) = try await URLSession.shared.download(for: request)

            // HTTP non-2xx → treat as failure. URLSession itself only
            // throws on transport errors, not on 4xx/5xx.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: tmpURL)
                updateState(id: itemId, to: .failed("HTTP \(http.statusCode)"))
                return
            }

            // URLSession's temp file lives in NSTemporaryDirectory() but
            // its name is gibberish. Rename so the share sheet shows the
            // real filename. If the server provided a better suggestion
            // via Content-Disposition, prefer that.
            let serverName = Self.filenameFromContentDisposition(response: response)
            let finalName = serverName ?? currentFilename(id: itemId) ?? "download"
            let dst = uniqueTempURL(filename: finalName)

            do {
                try FileManager.default.moveItem(at: tmpURL, to: dst)
            } catch {
                // Move failed (rare — probably name collision we didn't
                // resolve). Fall back to the original tmp file; the user
                // still gets the bytes, just with an ugly name.
                updateState(id: itemId, to: .finished(tmpURL))
                renameItem(id: itemId, to: tmpURL.lastPathComponent)
                pendingShare = tmpURL
                return
            }

            renameItem(id: itemId, to: dst.lastPathComponent)
            updateState(id: itemId, to: .finished(dst))
            pendingShare = dst
        } catch {
            updateState(id: itemId, to: .failed(error.localizedDescription))
        }
    }

    private func appendFailed(url: URL, filename: String, reason: String) {
        prepend(Item(id: UUID(),
                     url: url,
                     filename: filename,
                     state: .failed(reason),
                     startedAt: Date()))
    }

    private func prepend(_ item: Item) {
        items.insert(item, at: 0)
        if items.count > 20 { items.removeLast(items.count - 20) }
    }

    private func updateState(id: UUID, to state: State) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = state
    }

    private func renameItem(id: UUID, to name: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].filename = name
    }

    private func currentFilename(id: UUID) -> String? {
        items.first(where: { $0.id == id })?.filename
    }

    // MARK: - helpers

    // Pick a temp-dir URL that doesn't collide. The system's tmp dir is
    // shared across the app, and consecutive downloads of the same file
    // would otherwise clobber each other. UUID prefix on the parent
    // directory keeps the visible filename clean.
    private func uniqueTempURL(filename: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    // Cookies stored without an explicit Domain default to the host that
    // set them (HostOnly). HTTPCookie carries `domain` as either the
    // exact host (HostOnly true) or a `.example.com`-style suffix. We
    // do the standard "host equals domain or ends with .domain" check.
    static func cookieMatches(cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let hostMatches = host == bareDomain || host.hasSuffix("." + bareDomain)
        if !hostMatches { return false }
        // Path match: cookie path must be a prefix of the request path.
        let path = url.path.isEmpty ? "/" : url.path
        if !path.hasPrefix(cookie.path) { return false }
        // Secure cookies require https.
        if cookie.isSecure && url.scheme != "https" { return false }
        // Expiry check.
        if let exp = cookie.expiresDate, exp < Date() { return false }
        return true
    }

    // Pull a filename out of the Content-Disposition header if present.
    // We honor the simple `filename="x"` form and the RFC 5987
    // `filename*=UTF-8''x` form. Not bulletproof, but covers 99% of what
    // servers actually send.
    static func filenameFromContentDisposition(response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        // HTTPURLResponse headers are case-insensitive via
        // value(forHTTPHeaderField:), and the iOS 13+ overload is
        // there for exactly this use.
        let cd: String?
        if #available(iOS 13.0, *) {
            cd = http.value(forHTTPHeaderField: "Content-Disposition")
        } else {
            cd = (http.allHeaderFields["Content-Disposition"] as? String)
        }
        guard let header = cd else { return nil }

        // Try RFC 5987 first (preferred when both forms are present
        // since it carries an explicit charset).
        if let range = header.range(of: #"filename\*=[^']*''([^;]+)"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            let captured = String(header[range])
            if let eq = captured.range(of: "''") {
                let raw = captured[eq.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let decoded = raw.removingPercentEncoding, !decoded.isEmpty {
                    return decoded
                }
            }
        }

        // Fallback: plain `filename="x"` / `filename=x`.
        if let range = header.range(of: #"filename=("([^"]+)"|([^;]+))"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            var value = String(header[range])
            if let eq = value.firstIndex(of: "=") {
                value = String(value[value.index(after: eq)...])
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !value.isEmpty { return value }
        }
        return nil
    }

    // Strip the `data:<mime>;base64,` prefix and decode the body.
    // Returns nil if the URL isn't base64-encoded (we don't support
    // percent-encoded data URLs — JS hook always uses readAsDataURL
    // which produces base64).
    static func decodeBase64DataURL(_ url: String) -> Data? {
        guard let commaIdx = url.firstIndex(of: ",") else { return nil }
        let header = url[..<commaIdx]
        let body = url[url.index(after: commaIdx)...]
        guard header.contains(";base64") else { return nil }
        // FileReader.readAsDataURL produces standard base64 (with
        // padding, no URL-safe chars), so the default decoder works.
        return Data(base64Encoded: String(body))
    }

    // For inline (blob/data) downloads: same logic as resolveFilename
    // but with a MIME-derived extension fallback when the suggested
    // name has none. SPAs sometimes pass `report` instead of
    // `report.xlsx`, and the iOS share sheet picks the "open with" app
    // off the extension, not the MIME.
    static func resolveInlineFilename(filename: String, mime: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "download" : trimmed
        // If the name already has any extension (a dot in the last
        // path component), trust it — author knows better than us.
        if let dot = base.lastIndex(of: "."), base.distance(from: dot, to: base.endIndex) <= 6 {
            return base
        }
        // MIME → extension table. Kept tiny on purpose: only the
        // formats this app actually expects to see. UTI lookup via
        // UniformTypeIdentifiers would be more general but pulls in
        // an extra import and an availability dance for one feature.
        let ext: String? = switch mime.lowercased() {
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx"
        case "application/vnd.ms-excel":                                          "xls"
        case "text/csv":                                                          "csv"
        case "application/json":                                                  "json"
        case "application/pdf":                                                   "pdf"
        case "application/zip":                                                   "zip"
        case "image/png":                                                         "png"
        case "image/jpeg":                                                        "jpg"
        case "image/gif":                                                         "gif"
        case "image/svg+xml":                                                     "svg"
        case "text/plain":                                                        "txt"
        case "text/markdown":                                                     "md"
        case "text/html":                                                         "html"
        default:                                                                  nil
        }
        return ext.map { "\(base).\($0)" } ?? base
    }

    // Filename priority for the *pre-download* item label (real name from
    // Content-Disposition overrides this once headers arrive):
    //   1. Server-suggested via the navigation decider (rare — the
    //      WebPage NavigationResponse doesn't expose it directly, but
    //      we may add a sniffer later).
    //   2. Last path component of the URL, percent-decoded.
    //   3. Timestamped "download" fallback so the share sheet always
    //      shows *something*.
    static func resolveFilename(url: URL, suggested: String?) -> String {
        if let s = suggested?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            return s
        }
        let last = url.lastPathComponent
        if !last.isEmpty && last != "/" {
            return last.removingPercentEncoding ?? last
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "download-\(f.string(from: Date()))"
    }
}
