import SwiftUI
import WebKit
import FetchCore

struct DetectedStream: Identifiable {
    let url: URL
    let label: String
    let referer: String?
    var id: String { url.absoluteString }
    var detail: String { (url.host ?? "") + " / " + url.lastPathComponent }
}
@MainActor final class VideoBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var streams: [DetectedStream] = []
    @Published var message = "Press Play on the page. Detected streams appear here."
    @Published var protected = false
    let webView: WKWebView
    private var handler: StreamHandler?
    init(page: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: Self.detectionScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        let proxy = StreamHandler(owner: self); handler = proxy
        config.userContentController.add(proxy, name: "fetchVideo")
        webView.navigationDelegate = self
        webView.load(URLRequest(url: page))
    }
    func record(_ body: Any) {
        guard let data = body as? [String: String] else { return }
        if data["type"] == "drm" { protected = true; message = "This player uses protected video. Fetch cannot download DRM content."; return }
        guard let raw = data["url"], let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil, raw.count <= 8192, !streams.contains(where: { $0.id == raw }), streams.count < 50 else { return }
        let type = data["type"] ?? "Video"
        streams.append(DetectedStream(url: url, label: type, referer: data["referer"]))
        message = "Choose the stream for your video. Pages may also contain video ads."
    }
    func context(for stream: DetectedStream) async throws -> VideoContext {
        guard !protected else { throw ServiceError.message("DRM-protected videos are unsupported.") }
        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let host = stream.url.host?.lowercased() ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return (host == domain || host.hasSuffix("." + domain)) && stream.url.path.hasPrefix(cookie.path) && (!cookie.isSecure || stream.url.scheme == "https")
        }
        let agent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String ?? "Mozilla/5.0"
        return VideoContext(url: stream.id, userAgent: agent, cookies: matching.map(VideoCookie.init), referer: stream.referer)
    }
    func stop() { webView.stopLoading(); webView.configuration.userContentController.removeScriptMessageHandler(forName: "fetchVideo") }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about"].contains(scheme) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { message = "Page could not open. Reload or use another video page." }
    static let detectionScript = #"""
    (() => {
      const send = (url, kind = '', fromVideo = false) => {
        try {
          const u = new URL(url, document.baseURI);
          if (!/^https?:$/.test(u.protocol)) return;
          const p = u.pathname.toLowerCase();
          if (!fromVideo && (/\.(ts|m4s|cmfv|cmfa)$/.test(p) || /mp2t/i.test(kind))) return;
          const type = /\.m3u8$/.test(p) || /mpegurl/i.test(kind) ? 'HLS stream' : /\.mpd$/.test(p) || /dash\+xml/i.test(kind) ? 'DASH stream' : /\.(mp4|webm|mov|m4v)$/.test(p) || /^video\//i.test(kind) ? 'Video file' : null;
          if (type) window.webkit.messageHandlers.fetchVideo.postMessage({url:u.href,type,referer:location.href.startsWith('http') ? location.href : document.referrer});
        } catch {}
      };
      const scan = () => {
        document.querySelectorAll('video, video source').forEach(v => {
          send(v.currentSrc || v.src, v.type || 'video/unknown', true);
          if (v.tagName === 'VIDEO' && !v.dataset.fetchWatching) {
            v.dataset.fetchWatching='1'; v.addEventListener('loadedmetadata',scan);
            v.addEventListener('encrypted',() => window.webkit.messageHandlers.fetchVideo.postMessage({type:'drm'}));
          }
        });
      };
      new PerformanceObserver(list => list.getEntries().forEach(e => send(e.name))).observe({entryTypes:['resource']});
      const originalFetch = window.fetch;
      window.fetch = function(...args) { return originalFetch.apply(this,args).then(r => { send(r.url,r.headers.get('content-type') || ''); return r; }); };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(...args) {
        this.addEventListener('load',() => send(this.responseURL,this.getResponseHeader('content-type') || ''));
        return open.apply(this,args);
      };
      const begin = () => { scan(); new MutationObserver(scan).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['src']}); };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded',begin); else begin();
    })();
    """#
}
private final class StreamHandler: NSObject, WKScriptMessageHandler {
    weak var owner: VideoBrowser?
    init(owner: VideoBrowser) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.record(message.body) }
}
private struct PlayerWebView: NSViewRepresentable {
    let browser: VideoBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
struct VideoBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: VideoBrowser
    @State private var selecting = false
    let choose: (VideoContext) -> Void
    init(page: URL, choose: @escaping (VideoContext) -> Void) { _browser = StateObject(wrappedValue: VideoBrowser(page: page)); self.choose = choose }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Find video in player").font(.title2.weight(.semibold)); Spacer(); Button("Reload") { browser.webView.reload() }; Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(browser.message).font(.callout).foregroundStyle(browser.protected ? Color(nsColor: NativePalette.error) : Color(nsColor: NativePalette.secondary))
            PlayerWebView(browser: browser).frame(minHeight: 330)
            if browser.streams.isEmpty { Label("Waiting for a video or stream playlist…", systemImage: "play.rectangle").foregroundStyle(Color(nsColor: NativePalette.secondary)) }
            else {
                ScrollView { VStack(spacing: 8) { ForEach(browser.streams) { stream in
                    HStack { VStack(alignment: .leading, spacing: 3) { Text(stream.label).font(.headline); Text(stream.detail).font(.caption).lineLimit(1).truncationMode(.middle) }; Spacer();
                        if let reference = stream.referer, let page = URL(string: reference), ["http", "https"].contains(page.scheme ?? ""), page != browser.webView.url {
                            Button("Open Player Page") { browser.webView.load(URLRequest(url: page)); browser.streams.removeAll() }
                        }
                        Button("Use This Video") { Task { await select(stream) } }.disabled(selecting || browser.protected) }
                    Divider()
                } } }.frame(height: 120)
            }
            Text("Private player session. Cookies are used only for this video's host and are not saved in history.").font(.caption).foregroundStyle(Color(nsColor: NativePalette.secondary))
        }.padding(20).frame(width: 880, height: 620).onDisappear { browser.stop() }
    }
    private func select(_ stream: DetectedStream) async {
        selecting = true
        defer { selecting = false }
        do { choose(try await browser.context(for: stream)); dismiss() } catch { browser.message = error.localizedDescription }
    }
}
