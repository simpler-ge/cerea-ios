import UIKit
import WebKit

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
    private var closeButton: UIButton!
    /// Web view starts below the close button when we draw one, flush with the
    /// safe area when we don't. Swapped in `updateCloseButtonVisibility`.
    private var webViewTopBelowButton: NSLayoutConstraint!
    private var webViewTopAtSafeArea: NSLayoutConstraint!

    /// Whether the SDK draws its own close button.
    ///
    /// `true` by default. Presented modally there is otherwise no way out of
    /// the chat: `.fullScreen` has no swipe-to-dismiss and we draw no
    /// navigation bar, so the user has to force-quit the app. Set this to
    /// `false` if you supply your own dismissal chrome. It is ignored — and no
    /// button is drawn — when this controller sits inside a
    /// `UINavigationController`, which already provides a back item.
    public var showsCloseButton: Bool = true {
        didSet { updateCloseButtonVisibility() }
    }

    /// Called after the user taps the close button and the controller has been
    /// dismissed (or popped). Use it to drop your reference to the chat.
    public var onClose: (() -> Void)?

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
        // Deliberately NOT registering a WKScriptMessageHandler. Doing so
        // creates a retain cycle (WKUserContentController retains the handler
        // strongly, the handler owns the WebView which owns the
        // contentController). We don't currently consume widget→native
        // messages, so the registration would leak the VC for no benefit.
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
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
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

    // MARK: - Dismissal

    /// Hide the SDK's own button when the host already provides a way back —
    /// i.e. we're inside a navigation controller — or when the integrator
    /// opted out via `showsCloseButton`.
    private func updateCloseButtonVisibility() {
        guard closeButton != nil else { return }
        let shows = showsCloseButton && navigationController == nil
        closeButton.isHidden = !shows
        // Reclaim the strip when the button is hidden, so integrators who
        // supply their own chrome still get a full-bleed widget.
        webViewTopBelowButton.isActive = false
        webViewTopAtSafeArea.isActive = false
        (shows ? webViewTopBelowButton : webViewTopAtSafeArea)?.isActive = true
    }

    public override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        updateCloseButtonVisibility()
    }

    @objc private func closeTapped() {
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
