import UIKit
import WebKit

/// Something the widget reports to the app. Delivered through
/// `CereaChatViewController.onEvent`.
public enum CereaChatEvent: String {
    /// The widget has loaded its configuration and theme.
    case ready
    /// The chat window is showing.
    case open
    /// The user tapped the close button in the widget's header. The
    /// controller closes itself right after reporting it.
    case close
}

/// Embeds the Cerea chat widget as a full-screen iOS view.
///
/// Usage:
/// ```swift
/// let chat = CereaChatViewController(
///   token: "L7kQp3...nVx2",
///   userToken: userTokenFromYourBackend,        // optional, enables history
///   attributes: ["name": "Luka", "plan": "pro"]
/// )
/// present(chat, animated: true)
///
/// // Dynamic context updates as the user navigates your app
/// chat.updateContext(["current_screen": "billing"])
///
/// // Optional: hear what the widget reports
/// chat.onEvent = { event in print("widget:", event) }
/// ```
///
/// `userToken` is an HS256 JWT signed by your backend with the agent's HMAC
/// secret (claims: `aud: "cerea-identity"`, `user_id`, `exp` ≤24h). When
/// supplied, the visitor's conversations persist across devices and reinstalls
/// and the widget's history drawer is enabled. Without it the session is
/// anonymous and scoped to one device/tab.
///
/// Renders inside a `WKWebView` pointed at `https://<host>/w/<token>`.
/// The web widget detects `surface=ios` and skips its launcher chrome so
/// it fills the available view.
///
/// Add to your `Info.plist` if you allow media attachments:
/// - `NSCameraUsageDescription`
/// - `NSPhotoLibraryUsageDescription`
public final class CereaChatViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {

    private let token: String
    private let userToken: String?
    private let host: String
    private var attributes: [String: Any]
    private var webView: WKWebView!
    private var userContent: WKUserContentController?
    /// Set once a close is under way, so the header button and the SDK's own
    /// button tapped together cannot dismiss twice or fire `onClose` twice.
    private var isClosing = false
    /// Whether the current page has reported `open`. Older widget builds
    /// report `close` while starting up, before `open`; acting on that would
    /// shut the chat as it appears. Reset on every page load.
    private var widgetOpened = false {
        didSet { updateCloseButtonVisibility() }
    }
    private var closeButton: UIButton!
    /// Web view starts below the close button when it has its own strip, flush
    /// with the safe area otherwise. Swapped in `updateCloseButtonVisibility`.
    private var webViewTopBelowButton: NSLayoutConstraint!
    private var webViewTopAtSafeArea: NSLayoutConstraint!
    /// Position of the SDK's button; differs between its strip and floating.
    private var closeButtonTrailing: NSLayoutConstraint!
    private var closeButtonTop: NSLayoutConstraint!

    /// Whether the SDK keeps its own close button on screen, in a strip above
    /// the widget.
    ///
    /// `false` by default: the widget's header has its own close button, and
    /// two stacked crosses looked broken. Until the widget reports that it is
    /// open, the SDK still floats its button over the top-trailing corner —
    /// `.fullScreen` has no swipe-to-dismiss, so a page that is slow or fails
    /// to load must not leave the user with no way out. Set `true` for the
    /// 0.1.3 layout. No button is drawn inside a `UINavigationController`,
    /// whose back item already covers it.
    public var showsCloseButton: Bool = false {
        didSet { updateCloseButtonVisibility() }
    }

    /// Called after the user closes the chat — with the SDK's own button or the
    /// one in the widget's header — and the controller has been dismissed (or
    /// popped). Use it to drop your reference to the chat.
    public var onClose: (() -> Void)?

    /// Called on the main thread for each event the widget reports: `.ready`,
    /// `.open`, and `.close` when the user taps the widget's header close
    /// button. You do not need to act on `.close` — the controller closes
    /// itself and then calls `onClose`.
    public var onEvent: ((CereaChatEvent) -> Void)?

    /// - parameters:
    ///   - token:      Public widget token from the Cerea dashboard.
    ///   - userToken:  Optional HS256 JWT (`aud: "cerea-identity"`) signed by
    ///                 your backend. Enables stable identity + history.
    ///   - host:       Override only if you self-host the widget.
    ///   - attributes: Initial context for the AI's system prompt.
    public init(
        token: String,
        userToken: String? = nil,
        host: String = "https://app.cerea.ai",
        attributes: [String: Any] = [:]
    ) {
        self.token = token
        self.userToken = userToken
        self.host = host
        self.attributes = attributes
        super.init(nibName: nil, bundle: nil)
        // Full-screen on iPhone; on iPad the integrator can override
        // modalPresentationStyle to .pageSheet or .formSheet after init.
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()

        // Inject window.cereaConfig + surface flag before any page script runs.
        // The optional userToken is set via Object.assign so it doesn't have
        // to be baked into the JSON; that keeps the JSON escape contract
        // simple. We additionally harden against U+2028 / U+2029 line
        // separators in the JSON body — they're valid JSON but were illegal
        // in pre-ES2019 JS string literals.
        let cereaConfigJson = escapeJsLineSeparators(
            (try? JSONSerialization.data(withJSONObject: attributes))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
        let userTokenAssign: String
        if let token = userToken,
           let data = try? JSONSerialization.data(
               withJSONObject: ["userToken": token]
           ),
           let encoded = String(data: data, encoding: .utf8) {
            userTokenAssign = "Object.assign(window.cereaConfig, "
                + escapeJsLineSeparators(encoded) + ");"
        } else {
            userTokenAssign = ""
        }
        // The widget fetches /api/webchat/... from page JS. WKWebView does
        // NOT copy the custom headers we set on the document request onto
        // those sub-requests, so the server's bundle-ID allowlist check would
        // reject them with 403 origin_not_allowed. Patch fetch/XHR at document
        // start so same-origin API calls carry the header too.
        let bundleIdJson = Self.jsonQuoted(Bundle.main.bundleIdentifier ?? "")
        let headerShim = """
        (function () {
          var BUNDLE_ID = \(bundleIdJson);
          var HEADER = 'X-Cerea-Bundle-Id';
          function sameOrigin(url) {
            try {
              return new URL(url, window.location.href).origin
                === window.location.origin;
            } catch (e) { return false; }
          }
          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function (input, init) {
              try {
                var url = (typeof input === 'string')
                  ? input
                  : (input && input.url) || '';
                if (sameOrigin(url)) {
                  if (typeof input !== 'string'
                      && typeof Request !== 'undefined'
                      && input instanceof Request) {
                    var rh = new Headers(input.headers);
                    rh.set(HEADER, BUNDLE_ID);
                    input = new Request(input, { headers: rh });
                  } else {
                    init = init || {};
                    var ih = new Headers(init.headers || {});
                    ih.set(HEADER, BUNDLE_ID);
                    init.headers = ih;
                  }
                }
              } catch (e) {}
              return origFetch.call(this, input, init);
            };
          }
          var origOpen = XMLHttpRequest.prototype.open;
          var origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (method, url) {
            try { this.__cereaSameOrigin = sameOrigin(url); } catch (e) {}
            return origOpen.apply(this, arguments);
          };
          XMLHttpRequest.prototype.send = function () {
            try {
              if (this.__cereaSameOrigin) {
                this.setRequestHeader(HEADER, BUNDLE_ID);
              }
            } catch (e) {}
            return origSend.apply(this, arguments);
          };
        })();
        """
        let inject = """
        \(headerShim)
        window.cereaConfig = \(cereaConfigJson);
        \(userTokenAssign)
        window.cereaSurface = 'ios';
        """
        userContent.addUserScript(WKUserScript(
            source: inject,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // The widget reports ready/open/close to a script message handler
        // named "cerea". WKUserContentController retains its handlers
        // strongly, and this controller owns the web view that owns the
        // content controller — registering `self` would leak the chat on every
        // dismissal. The proxy holds us weakly, which breaks that cycle.
        userContent.add(
            WeakScriptMessageProxy(owner: self),
            name: Self.hostBridgeName
        )
        self.userContent = userContent
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view = UIView()
        view.backgroundColor = .systemBackground
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            // Track the keyboard instead of running under it. WKWebView does
            // not resize for the keyboard on its own, so a full-height web view
            // keeps laying out at full height and the widget's fixed header
            // scrolls out of sight the moment the composer takes focus.
            webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Close affordance. It gets its own strip above the web view rather
        // than floating over it: the widget's header is full-bleed, so an
        // overlaid button lands on top of the customer's logo or its own
        // history/new-chat controls.
        closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = NSLocalizedString(
            "Close chat",
            comment: "Accessibility label for the Cerea chat close button"
        )
        closeButton.tintColor = .label
        closeButton.backgroundColor = .secondarySystemBackground
        closeButton.layer.cornerRadius = 16
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        if #available(iOS 13.0, *) {
            closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        } else {
            closeButton.setTitle("✕", for: .normal)
        }
        view.addSubview(closeButton)
        closeButtonTrailing = closeButton.trailingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        closeButtonTop = closeButton.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            closeButtonTrailing,
            closeButtonTop,
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        webViewTopBelowButton = webView.topAnchor.constraint(
            equalTo: closeButton.bottomAnchor, constant: 6)
        webViewTopAtSafeArea = webView.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor)
        // Resolved in updateCloseButtonVisibility(), called from viewDidLoad.
        webViewTopBelowButton.isActive = true
    }

    deinit {
        userContent?.removeScriptMessageHandler(forName: Self.hostBridgeName)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Shown again after an earlier close — the same instance may be
        // re-presented, and it must be closable again.
        isClosing = false
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        updateCloseButtonVisibility()
        guard let url = URL(string: "\(host)/w/\(token)") else { return }
        var request = URLRequest(url: url)
        // Bundle ID is the iOS "origin" for allowlist verification.
        if let bundleId = Bundle.main.bundleIdentifier {
            request.setValue(bundleId, forHTTPHeaderField: "X-Cerea-Bundle-Id")
        }
        webView.load(request)
    }

    /// Patch additional context into the active conversation. Triggers no
    /// AI turn by itself; the next user message will see the merged context.
    public func updateContext(_ patch: [String: Any]) {
        attributes.merge(patch) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: patch),
              let json = String(data: data, encoding: .utf8) else { return }
        let safe = escapeJsLineSeparators(json)
        let js = """
        window.postMessage({
          ns: 'cerea.widget.v1',
          type: 'context-patch',
          payload: \(safe)
        }, '*');
        """
        webView.evaluateJavaScript(js)
    }

    // MARK: - WKNavigationDelegate

    /// Route external links to Safari instead of trapping the user inside
    /// the chat WebView with no back affordance. Same-host navigations and
    /// the initial `/w/<token>` load stay in-app.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url,
              let hostURL = URL(string: host),
              navigationAction.navigationType == .linkActivated
        else {
            decisionHandler(.allow)
            return
        }
        if target.host == hostURL.host {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            UIApplication.shared.open(target)
        }
    }

    /// A new page starts over: its `close` counts only after its own `open`.
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        widgetOpened = false
    }

    // MARK: - Dismissal

    /// Three states. Inside a navigation controller: no button, the back item
    /// covers it. `showsCloseButton`: the button keeps its own strip above the
    /// widget. Otherwise it floats over the widget only until the page reports
    /// `open` — by then the header's close button is on screen and works.
    private func updateCloseButtonVisibility() {
        guard closeButton != nil else { return }
        let hostHasBack = navigationController != nil
        let inStrip = showsCloseButton && !hostHasBack
        let floating = !showsCloseButton && !hostHasBack && !widgetOpened
        closeButton.isHidden = !(inStrip || floating)
        // Floating, it sits exactly over the widget header's own 32pt close
        // button (22pt header padding, centred in the row), so the user sees
        // one cross whichever of the two is live.
        closeButtonTrailing.constant = inStrip ? -12 : -22
        closeButtonTop.constant = inStrip ? 6 : 22
        webViewTopBelowButton.isActive = false
        webViewTopAtSafeArea.isActive = false
        (inStrip ? webViewTopBelowButton : webViewTopAtSafeArea)?.isActive = true
    }

    public override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        updateCloseButtonVisibility()
    }

    @objc private func closeTapped() {
        close()
    }

    /// The one way out, shared by the SDK's button and the widget's header
    /// button, so both leave the host in the same state.
    private func close() {
        guard !isClosing else { return }
        isClosing = true
        if let nav = navigationController, nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
            onClose?()
        } else if presentingViewController != nil {
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.onClose?()
            }
        } else {
            // Embedded as a child view controller: detach ourselves so the
            // host isn't left with a dead view it never asked to remove.
            willMove(toParent: nil)
            view.removeFromSuperview()
            removeFromParent()
            onClose?()
        }
    }

    // MARK: - Widget → app events

    /// Name the widget posts to: `window.webkit.messageHandlers.cerea`.
    private static let hostBridgeName = "cerea"
    private static let hostBridgeNamespace = "cerea.widget.v1"

    /// Only the widget's own top-level page may drive the controller. A
    /// message from any other frame or origin — an embedded iframe, or a page
    /// reached by navigation — is ignored.
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == Self.hostBridgeName,
              message.frameInfo.isMainFrame,
              let widgetHost = URL(string: host)?.host,
              message.frameInfo.securityOrigin.host == widgetHost,
              let body = message.body as? [String: Any],
              body["ns"] as? String == Self.hostBridgeNamespace,
              let type = body["type"] as? String,
              let event = CereaChatEvent(rawValue: type)
        else { return }
        switch event {
        case .open:
            widgetOpened = true
        case .close:
            // Start-up state from an older widget, not the user asking out.
            guard widgetOpened else { return }
        case .ready:
            break
        }
        onEvent?(event)
        if event == .close { close() }
    }

    // MARK: - WKUIDelegate (file uploads)
    //
    // We deliberately do NOT implement
    // `webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`.
    //
    // That WKUIDelegate method — and `WKOpenPanelParameters` — only became
    // available on iOS in 18.4; on earlier releases they are macOS-only.
    // Referencing them unconditionally breaks compilation for any integrator
    // whose deployment target is below 18.4, including our own stated
    // minimum of iOS 15.
    //
    // Leaving it unimplemented is also the better behaviour: WKWebView then
    // falls back to the system file picker, so `<input type="file">` works
    // on every supported iOS version. The previous implementation returned
    // `completionHandler(nil)`, which silently cancelled every upload.
    //
    // Integrators who need a custom picker can subclass and implement it
    // themselves behind `@available(iOS 18.4, *)`.

    // MARK: - Helpers

    /// JSON-quote an arbitrary string so it can be embedded in injected JS
    /// without escaping hazards.
    private static func jsonQuoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let s = String(data: data, encoding: .utf8),
              s.count >= 2
        else { return "\"\"" }
        return String(s.dropFirst().dropLast())
    }


    /// U+2028 / U+2029 are legal in JSON but were illegal in pre-ES2019 JS
    /// string literals. Modern JavaScriptCore tolerates them, but escape
    /// defensively so a single backported WebView can't trigger an injection.
    private func escapeJsLineSeparators(_ json: String) -> String {
        let lineSep = "\u{2028}"
        let paraSep = "\u{2029}"
        return json
            .replacingOccurrences(of: lineSep, with: "\\u2028")
            .replacingOccurrences(of: paraSep, with: "\\u2029")
    }
}

/// Forwards script messages to the chat without retaining it. See the
/// registration in `loadView` for the cycle this breaks.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var owner: CereaChatViewController?

    init(owner: CereaChatViewController) {
        self.owner = owner
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.receive(message)
    }
}
