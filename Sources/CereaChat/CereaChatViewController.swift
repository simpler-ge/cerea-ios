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
        let inject = """
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
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
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

    // MARK: - WKUIDelegate (file uploads)

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        // Minimal implementation — apps with file-upload UX should subclass
        // and present a UIDocumentPickerViewController / PHPickerViewController.
        completionHandler(nil)
    }

    // MARK: - Helpers

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
