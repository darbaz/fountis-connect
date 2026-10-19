# FOUNTIS Connect for iOS

`FountisConnect` shows FOUNTIS studies to the people in your app, in a full-screen sheet, and matches them on the device
from attributes your server signs. Swift package, iOS 15 or later. The API has the same names as every other FOUNTIS
Connect SDK. Full guide: https://fountis.org/connect/docs

## Install

In Xcode choose File > Add Package Dependencies and enter `https://github.com/darbaz/fountis-connect`, product `FountisConnect`.

## Use

```swift
// At launch (App.init or application(_:didFinishLaunchingWithOptions:)), not in a view:
FountisConnect.start(key: "pk_live_...")
FountisConnect.setUserToken { try await myServer.fountisToken() }   // nil only when nobody is signed in
FountisConnect.enableNotifications()                                // optional

let result = await FountisConnect.show()                            // .noFill, .dismissed or .completed
```

For the background check add `BGTaskSchedulerPermittedIdentifiers` = `org.fountis.connect.refresh` and the `fetch`
background mode to Info.plist. Without them the SDK still works while the app is open.

Return `nil` from the token function only when nobody is signed in; throw when you cannot get a token. When nobody is
signed in and FOUNTIS has switched guests on for your app, the SDK offers the free studies marked open to guests.

## Guest attestation (App Attest)

FOUNTIS can ask the SDK to prove that a guest session comes from your genuine app on a genuine device. This applies to
guests only; signed-in people are not affected, and nothing is shown to the person. To support it:

1. Add the **App Attest** capability to your app target (Signing & Capabilities > + Capability > App Attest). This sets the
   entitlement `com.apple.developer.devicecheck.appattest-environment` to `production` for release builds. Xcode uses
   `development` for debug builds; FOUNTIS accepts those keys from sandbox keys (`pk_test_`) only.
2. Give FOUNTIS your Apple Team ID and bundle identifier.

There is no code to add. The SDK registers one App Attest key per install and attests each guest session. App Attest does
not run on the iOS Simulator or on devices without it: there the SDK reports "unsupported", and if FOUNTIS is set to
enforce attestation for your app, that device is offered no guest studies. On a real device without the entitlement App
Attest fails, which counts the same as having no attestation.

## Tests

`swift test` does not apply (the package uses UIKit). Run the unit tests on a simulator:
`xcodebuild test -scheme FountisConnect -destination 'platform=iOS Simulator,name=iPhone 17'`.
