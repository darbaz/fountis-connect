import UIKit
import WebKit

/// The SDK-owned survey screen. It is always presented full screen (no sheet, no swipe-to-dismiss) and hosts the
/// bundled FOUNTIS-branded engine edge to edge in a locked-down WKWebView; the engine handles the safe areas
/// itself (`viewport-fit=cover`) and is the only way out (its close button sends `{type:"close"}`).
/// The controller relays the engine's messages to the API (the engine never touches the network in native mode).
@MainActor
final class SheetController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    struct Finish {
        /// "complete", "screen_out", "quota_full", or nil when closed before the end.
        let outcome: String?
        /// A fatal API code (not_eligible, closed, ...) was shown.
        let fatal: String?
        /// UIKit never started showing the sheet (see `abandonIfNotShown`): nothing was shown, so it is neither completed nor dismissed.
        var unavailable = false
    }

    private let engineURL: URL
    private let initJSON: String
    private let api: ApiClient
    private let attemptToken: String
    private let onShown: () -> Void
    private let onFinish: (Finish) -> Void

    private var webView: WKWebView!
    private var cover: UIView?
    private var inFlight = Set<String>()
    private var outcome: String?
    private var fatal: String?
    private var navigated = false
    private var appeared = false
    private var finished = false

    /// `onShown` runs once, when UIKit first starts showing the sheet. `onFinish` runs exactly once, ever.
    init(engineURL: URL, initPayload: [String: Any], api: ApiClient, attemptToken: String, onShown: @escaping () -> Void, onFinish: @escaping (Finish) -> Void) {
        self.engineURL = engineURL
        let data = (try? JSONSerialization.data(withJSONObject: initPayload)) ?? Data("{}".utf8)
        self.initJSON = String(decoding: data, as: UTF8.self)
        self.api = api
        self.attemptToken = attemptToken
        self.onShown = onShown
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        isModalInPresentation = true
        modalTransitionStyle = .coverVertical
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.ground
    }

    /// Built when UIKit first starts showing the sheet, not in `viewDidLoad`: UIKit loads the view of a presentation it
    /// then refuses, and a sheet nobody sees must not start the engine.
    private func buildWebView() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.allowsInlineMediaPlayback = true
        cfg.dataDetectorTypes = []
        cfg.userContentController.add(WeakHandler(self), name: "fountis")
        webView = WKWebView(frame: .zero, configuration: cfg)
        if #available(iOS 16.4, *) { webView.isInspectable = false }
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false   // the engine scrolls its own body; a scrolling document is what slides the header under the status bar when the keyboard opens
        webView.scrollView.contentInsetAdjustmentBehavior = .never   // edge to edge: the engine reads env(safe-area-inset-*)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        webView.loadFileURL(engineURL, allowingReadAccessTo: engineURL.deletingLastPathComponent())

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(hideContent), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(showContent), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// FOUNTIS page ground (#F2F5F4), the same colour the engine paints, so nothing flashes before it loads.
    private static let ground = UIColor(red: 0xF2 / 255, green: 0xF5 / 255, blue: 0xF4 / 255, alpha: 1)

    // The engine's ground is light, so the status bar content is dark.
    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
    override var prefersStatusBarHidden: Bool { false }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !appeared, !finished else { return }
        appeared = true
        buildWebView()
        onShown()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // UIKit showed a sheet the presenter had already given up on: its result is out, so just get it off the screen.
        if finished, presentingViewController != nil { dismiss(animated: false) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { finish() }
    }

    /// The presenter's watchdog: if UIKit has not started showing the sheet by now, it is not going to (a refused
    /// presentation only logs a warning), so finish it as `unavailable`. Goes through `finish()`, so `onFinish` still
    /// runs once however this races with a late appearance. A sheet UIKit does show after this loads nothing.
    func abandonIfNotShown() {
        guard !appeared, !finished else { return }
        finish(unavailable: true)
    }

    private func finish(unavailable: Bool = false) {
        guard !finished else { return }
        finished = true
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "fountis")
        onFinish(Finish(outcome: outcome, fatal: fatal, unavailable: unavailable))
    }

    private func close() {
        if presentingViewController != nil { dismiss(animated: true) { [weak self] in self?.finish() } } else { finish() }
    }

    // MARK: privacy cover

    @objc private func hideContent() {
        guard cover == nil else { return }
        let v = UIView(frame: view.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.backgroundColor = Self.ground
        view.addSubview(v)
        cover = v
    }

    @objc private func showContent() {
        cover?.removeFromSuperview()
        cover = nil
    }

    // MARK: navigation lock

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !navigated, navigationAction.request.url?.isFileURL == true {
            navigated = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fcLog.debug("web content process terminated")
        close()
    }

    // MARK: engine messages

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            send(js: "window.FountisEngine && window.FountisEngine.init(\(initJSON))")
        case "answer":
            guard let code = body["code"] as? String else { return }
            handleAnswer(code: code, value: body["value"] ?? NSNull())
        case "consent":
            handleConsent()
        case "complete":
            handleComplete()
        case "done":
            if let o = body["outcome"] as? String { outcome = o }
        case "close":
            close()
        default:
            break // progress, height: nothing to do on the host
        }
    }

    private func reply(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        send(js: "window.FountisEngine && window.FountisEngine.receive(\(String(decoding: d, as: UTF8.self)))")
    }

    private func send(js: String) { webView?.evaluateJavaScript(js, completionHandler: nil) }

    private func fail(_ error: Error) {
        if let e = error as? APIError {
            if e.isFatal { fatal = e.code }
            reply(["type": "error", "message": e.message, "code": e.code])
        } else {
            reply(["type": "error", "message": "network"])
        }
    }

    /// Runs `work` unless the same request is already in flight (the engine re-sends every 5 s).
    private func once(_ key: String, _ work: @escaping () async -> Void) {
        guard inFlight.insert(key).inserted else { return }
        Task { [weak self] in
            await work()
            self?.inFlight.remove(key)
        }
    }

    private func handleAnswer(code: String, value: Any) {
        let sig = "a:" + code + ":" + ((try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "")
        once(sig) { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.api.putAnswer(code: code, value: value, attemptToken: self.attemptToken)
                self.reply(["type": "ack", "code": code, "stop": r["stop"] ?? NSNull()])
            } catch { self.fail(error) }
        }
    }

    private func handleConsent() {
        once("consent") { [weak self] in
            guard let self else { return }
            do {
                try await self.api.consent(attemptToken: self.attemptToken)
                self.reply(["type": "ack", "code": "consent", "stop": NSNull()])
            } catch { self.fail(error) }
        }
    }

    private func handleComplete() {
        once("complete") { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.api.complete(attemptToken: self.attemptToken)
                let o = (r["outcome"] as? String) ?? "complete"
                self.outcome = o
                self.reply(["type": "result", "outcome": o, "reward": r["reward"] ?? NSNull()])
            } catch { self.fail(error) }
        }
    }
}

/// WKUserContentController retains its handlers strongly; this proxy avoids a retain cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
