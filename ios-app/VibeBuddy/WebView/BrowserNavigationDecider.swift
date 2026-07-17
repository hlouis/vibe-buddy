import Foundation
import WebKit

// Bridges the iOS 26 SwiftUI WebPage navigation policy hooks to our
// BrowserDownloadManager.
//
// Why a struct: WebPage(configuration:navigationDecider:) takes
// `some WebPage.NavigationDeciding` and forwards mutating calls. A
// value type that holds a reference (to the manager + cookie store)
// is the cleanest way to participate — the decider itself owns nothing
// stateful, the manager does.
//
// Detection strategy (two complementary hooks):
//
//   1. NavigationAction phase: `shouldPerformDownload == true` when the
//      page used `<a download href="...">` — the HTML5 explicit
//      download attribute. This fires before the request goes out, so
//      we cancel and re-issue via URLSession.
//
//   2. NavigationResponse phase: we look at the response headers
//      ourselves and intercept if:
//        - canShowMimeType is false (PDF without an inline viewer,
//          .zip, .csv, .xlsx, etc.), OR
//        - Content-Disposition contains "attachment".
//      Cancel here too and re-fetch.
//
// We never return `.download`. WebPage's NavigationDeciding accepts it
// but provides no callback to deliver the resulting WKDownload, so the
// download would be invisible to us. `.cancel` + URLSession is the only
// path that gives us full control.
struct BrowserNavigationDecider: WebPage.NavigationDeciding {

    // Strong ref is fine — the manager outlives the decider (it's owned
    // by VibeBuddyApp). WebPage retains the decider internally.
    let manager: BrowserDownloadManager

    // Captured at construction time. WKWebsiteDataStore is a reference
    // type so this reflects whatever cookies the live WebView has
    // accumulated, not a snapshot.
    let cookieStore: WKHTTPCookieStore

    // MARK: - NavigationDeciding

    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload {
            await hijack(url: action.request.url, suggestedFilename: nil)
            return .cancel
        }
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        let url = response.response.url
        let disposition = (response.response as? HTTPURLResponse)
            .flatMap { $0.value(forHTTPHeaderField: "Content-Disposition") } ?? ""
        let isAttachment = disposition.range(of: "attachment", options: .caseInsensitive) != nil

        if !response.canShowMimeType || isAttachment {
            // Try to lift the server-suggested filename off the
            // response now — it's the most reliable source we'll ever
            // have. The manager will overwrite this once URLSession
            // sees the (identical) header, but pre-seeding makes the
            // status row show the right name immediately.
            let suggested = BrowserDownloadManager
                .filenameFromContentDisposition(response: response.response)
                ?? response.response.suggestedFilename
            await hijack(url: url, suggestedFilename: suggested)
            return .cancel
        }
        return .allow
    }

    // MARK: - private

    @MainActor
    private func hijack(url: URL?, suggestedFilename: String?) async {
        guard let url else { return }
        let cookies = await cookieStore.allCookies()
        manager.start(url: url,
                      suggestedFilename: suggestedFilename,
                      cookies: cookies)
    }
}
