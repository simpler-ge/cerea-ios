# Cerea iOS SDK

Embed a Cerea chat agent inside your iOS app — a full-screen
`UIViewController` wrapping a `WKWebView` pointed at our hosted widget.

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…**

```
https://github.com/simpler-ge/cerea-ios
```

Or in `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/simpler-ge/cerea-ios", from: "0.1.1")
]
```

Minimum iOS 15.

## Use

```swift
import CereaChat

let chat = CereaChatViewController(
  token: "<widget-token-from-dashboard>",
  userToken: userTokenFromYourBackend,        // optional, enables history
  attributes: ["plan": "pro"]
)
present(chat, animated: true)

// Push context as the user navigates your app
chat.updateContext(["current_screen": "billing"])
```

### Identity & history (optional)

If `userToken` is provided — an HS256 JWT signed by your backend with
the agent's HMAC secret (claims: `aud: "cerea-identity"`, `user_id`,
`exp` ≤24h) — the visitor's conversations persist across devices and
reinstalls, and the in-widget history drawer activates. Without it,
each install is anonymous and scoped to that device.

### Self-hosted widget

```swift
CereaChatViewController(
  token: "...",
  host: "https://chat.example.com"   // your hosted widget URL
)
```

### iPad presentation

The default `modalPresentationStyle` is `.fullScreen`. On iPad you'll
typically want `.pageSheet` or `.formSheet`:

```swift
let chat = CereaChatViewController(token: "...")
chat.modalPresentationStyle = .pageSheet
present(chat, animated: true)
```

## Required Info.plist (only if you allow file uploads)

```xml
<key>NSCameraUsageDescription</key>
<string>Allow camera access to send photos in chat.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Allow photo library access to attach images.</string>
```

## Configure the agent

1. In the Cerea dashboard, go to **Agents → General Chat → Create Agent**.
2. Pick **iOS SDK** as the surface.
3. Add your app's Bundle Identifier (e.g. `com.acme.app`) to the allowlist.
4. Copy the widget token and paste it into the SDK call above.

## Security notes

The SDK never registers a `WKScriptMessageHandler` (avoids the retain
cycle that would leak the view controller across dismissal), routes
external link taps to Safari via `WKNavigationDelegate`, and escapes
U+2028 / U+2029 in injected JSON. The visitor's Bundle ID is sent as
`X-Cerea-Bundle-Id` for server-side allowlist verification.

## License

MIT — see `LICENSE`.
