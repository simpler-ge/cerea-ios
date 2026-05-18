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
public final class CereaChatViewController: UIViewController, WKUIDelegate, WKScriptMessageHandler {

    /// Override if you self-host the widget on a custom domain.
    public var host: String = "https://app.cerea.ai"

    private let token: String
    private let userToken: String?
    private var attributes: [String: Any]
    private var webView: WKWebView!

    public init(
        token: String,
        userToken: String? = nil,
        attributes: [String: Any] = [:]
    ) {
        self.token = token
        self.userToken = userToken
        self.attributes = attributes
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "cerea")

        // Inject window.cereaConfig + surface flag before any page script runs.
        // The optional userToken is set via assignment (rather than baked into
        // the JSON) so it can be passed straight through JSONSerialization
        // without escaping concerns — the widget reads `cereaConfig.userToken`
        // when bootstrapping the session.
        let cereaConfigJson = (try? JSONSerialization.data(withJSONObject: attributes))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let userTokenAssign: String
        if let userToken = userToken,
           let data = try? JSONSerialization.data(
               withJSONObject: ["userToken": userToken]
           ),
           let encoded = String(data: data, encoding: .utf8) {
            userTokenAssign = "Object.assign(window.cereaConfig, \(encoded));"
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
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
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
        let js = """
        window.postMessage({
          ns: 'cerea.widget.v1',
          type: 'context-patch',
          payload: \(json)
        }, '*');
        """
        webView.evaluateJavaScript(js)
    }

    // MARK: - WKUIDelegate (file uploads)

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        // Minimal implementation — apps with file-upload UX should override.
        completionHandler(nil)
    }

    // MARK: - WKScriptMessageHandler (widget → native bridge)

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Reserved for future widget→native callbacks (e.g. close button).
        _ = message.body
    }
}
