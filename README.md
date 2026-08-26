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

Minimum iOS 15 to **build**.

> **Runtime caveat.** The hosted widget calls `crypto.randomUUID()`,
> which WKWebView only provides from **iOS 15.4**. On iOS 15.0–15.3 the
> SDK compiles and the view loads, but the widget cannot create a chat
> session. If you must support 15.0–15.3, the widget needs a
> `crypto.randomUUID` polyfill server-side.

## Use

```swift
import CereaChat

let chat = CereaChatViewController(
  token: "<widget-token-from-dashboard>",
  userToken: userTokenFromYourBackend,        // identity + history (see below)
  attributes: ["plan": "pro"]
)
present(chat, animated: true)

// Push context as the user navigates your app
chat.updateContext(["current_screen": "billing"])
```

### Closing the chat

Presented modally, the controller draws its own close button (top-trailing,
inside the safe area) and dismisses itself when tapped. `.fullScreen` has no
swipe-to-dismiss, so without that button the user has no way back out.

```swift
chat.onClose = { print("chat closed") }   // optional
chat.showsCloseButton = false             // you supply your own chrome
```

The button hides itself automatically when the controller is pushed onto a
`UINavigationController` — the back item already covers it.

### Identity & history

If `userToken` is provided — an HS256 JWT signed by your backend with
the agent's HMAC secret (claims: `aud: "cerea-identity"`, `user_id`,
`exp` ≤24h) — the visitor's conversations persist across devices and
reinstalls, and the in-widget history drawer activates.

**A visitor identity is required to start a conversation, and on iOS
`userToken` is the only way to supply one.** The session endpoint rejects
anonymous visitors with `identity_required`.

The pre-chat form is **not** an alternative here: the widget only renders
it on the `webchat` surface, so enabling it on a mobile agent has no
effect no matter what the dashboard shows.

Without a `userToken` the widget still renders and shows the greeting —
so it looks like it is working — but no session exists, sending a message
does nothing, and attaching a file fails with `401`.

The JWT must be signed with the agent's **HMAC secret exactly as shown in
the dashboard** (the hex string is used as UTF-8 text, not decoded to
bytes) and must include an `iat` claim — tokens without `iat` are
rejected with `invalid_user_token`. Use `user_id`; `sub` alone is not
accepted.

```
header  { "alg": "HS256", "typ": "JWT" }
payload { "aud": "cerea-identity", "user_id": "<your id>",
          "iat": <now>, "exp": <now + ≤86400> }
```

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
