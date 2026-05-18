# Cerea iOS SDK

Embed a Cerea General Chat agent in your iOS app.

## Install

In Xcode: **File → Add Package Dependencies…** and paste:

```
https://github.com/simpler-ge/cerea-ios
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/simpler-ge/cerea-ios", from: "0.1.0")
]
```

## Use

```swift
import CereaChat

let chat = CereaChatViewController(
    token: "your-widget-token",
    attributes: [
        "user_id": "user-42",
        "name": "Luka",
        "plan": "pro"
    ]
)
present(chat, animated: true)

// Dynamic context updates
chat.updateContext(["current_screen": "billing"])
```

## Required `Info.plist` keys

Only needed if you allow visitors to attach media:

- `NSCameraUsageDescription` — "Allow camera access to send photos in chat."
- `NSPhotoLibraryUsageDescription` — "Allow photo library access to attach images."

## Configure the agent

1. In the Cerea dashboard, go to **Agents → General Chat → Create Agent**.
2. Pick **iOS SDK** as the surface.
3. Add your app's bundle ID (e.g. `com.acme.app`) to the allowlist.
4. Copy the widget token and paste it into the SDK call.
