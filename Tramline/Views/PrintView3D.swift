import SwiftUI
import WebKit

/// The GUI's 3D view, `shared/view.js`, loaded from the Pi into a web view, so the phone
/// always draws with the version that matches its server and nothing is copied into the
/// app. The page is the app's own, given the Pi's read-only address as its base, so the
/// scripts and the model it fetches from `/api/model/{id}` are same-origin.
struct PrintView3D: UIViewRepresentable {
    let store: PrinterStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "tl")
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.viewBackground)
        web.scrollView.backgroundColor = UIColor(Theme.viewBackground)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.navigationDelegate = context.coordinator
        #if DEBUG
        web.isInspectable = true
        #endif
        context.coordinator.web = web
        context.coordinator.load()
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.sync()
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "tl")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let store: PrinterStore
        weak var web: WKWebView?
        private var base: URL?
        private var ready = false
        private var lastSent = ""
        private var retry: Task<Void, Never>?

        init(store: PrinterStore) {
            self.store = store
        }

        func load() {
            let base = store.client.webBase
            self.base = base
            ready = false
            lastSent = ""
            web?.loadHTMLString(Self.page, baseURL: base)
        }

        /// Hands the latest polls to the view, as `pollPage` and `showFull` do in the GUI.
        func sync() {
            // Reading these here is what makes SwiftUI call updateUIView when they change.
            let page = store.pageJSON
            let full = store.fullJSON
            let tram = store.showTramInView
            let mesh = store.meshShown != nil
            let heights = store.heights.flatMap { try? JSON.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "null"

            if store.client.webBase != base || (!ready && store.reachable && store.page != nil && retry == nil) {
                scheduleReload()
                return
            }
            guard ready else { return }
            let call = "tl.sync(\(page), \(full), \(tram), \(mesh), \(heights), \(Limits.tramTolerance))"
            guard call != lastSent else { return }
            lastSent = call
            web?.evaluateJavaScript(call, completionHandler: nil)
        }

        private func scheduleReload() {
            retry?.cancel()
            retry = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                retry = nil
                load()
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["type"] as? String {
            case "ready":
                ready = true
                retry?.cancel()
                retry = nil
                store.viewDetails.loaded = true
                store.viewDetails.ok = body["ok"] as? Bool ?? false
                lastSent = ""
                sync()
            case "failed":
                log(body["text"])
                ready = false
                store.viewDetails.loaded = false
            case "details":
                var d = store.viewDetails
                d.layer = body["layer"] as? String ?? "–"
                d.left = body["left"] as? String ?? "–"
                d.modelMissing = body["modelMissing"] as? Bool ?? false
                if d != store.viewDetails { store.viewDetails = d }
            case "log":
                log(body["text"])
            default:
                break
            }
        }

        private func log(_ text: Any?) {
            #if DEBUG
            print("tramline-view: \(text ?? "")")
            #endif
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("didFail \(error)")
            ready = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("didFailProvisional \(error)")
            ready = false
        }

        /// Links never open in the view.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .other ? .allow : .cancel
        }

        // The page: a canvas, the tram labels, and a little glue. `sync` takes the page
        // status and full status as the Pi sent them, and what to show, with the GUI's
        // rules worked out in Swift.
        static let page = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <style>
          html, body { margin: 0; height: 100%; overflow: hidden; background: #15181c; -webkit-user-select: none; -webkit-touch-callout: none; }
          canvas { display: block; width: 100%; height: 100%; touch-action: none; }
          #labels { position: fixed; inset: 0; pointer-events: none; overflow: hidden; }
          #labels span { position: absolute; left: 0; top: 0; padding: 3px 7px;
            font: 600 12px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: nowrap;
            color: #e8eaed; background: rgba(21, 24, 28, 0.82); border: 1px solid #343a43; border-radius: 6px; }
          #labels span.bad { color: #f2645a; border-color: #f2645a; }
        </style>
        </head><body>
        <canvas id="view"></canvas>
        <div id="labels"></div>
        <script>
          const post = (m) => window.webkit.messageHandlers.tl.postMessage(m);
          window.addEventListener("error", (e) => {
            if (e.target && e.target.src) post({ type: "failed", text: "couldn't load " + e.target.src });
            else post({ type: "log", text: String(e.message) + " at " + e.filename + ":" + e.lineno });
          }, true);
          for (const level of ["error", "warn"]) {
            const orig = console[level];
            console[level] = (...a) => { post({ type: "log", text: level + ": " + a.map(String).join(" ") }); orig.apply(console, a); };
          }
        </script>
        <script src="shared/status.js" onerror="post({type:'failed'})"></script>
        <script src="shared/view.js" onerror="post({type:'failed'})"></script>
        <script>
          if (typeof PrintView === "function") {
            const view = new PrintView(document.getElementById("view"), (id) => `/api/model/${id}`, document.getElementById("labels"));
            let last = "";
            window.tl = {
              sync(page, full, tram, mesh, heights, tolerance) {
                if (!view.ok) return;
                view.update(page ? page.print : null);
                view.updateTram(tram && full ? full.tram : null, tolerance);
                view.updateMesh(mesh && full ? full.print : null);
                view.updateHeights(heights);
              },
            };
            setInterval(() => {
              const d = view.ok ? view.details() : { layer: "–", left: "–" };
              const m = { type: "details", layer: d.layer, left: d.left, modelMissing: Boolean(view.modelMissing) };
              const key = JSON.stringify(m);
              if (key !== last) { last = key; post(m); }
            }, 500);
            post({ type: "ready", ok: view.ok });
          } else {
            post({ type: "failed", text: "view.js didn't define PrintView" });
          }
        </script>
        </body></html>
        """
    }
}
