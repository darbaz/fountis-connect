# FOUNTIS Connect

FOUNTIS Connect lets partner apps and websites show FOUNTIS research studies to the people who match, inside the
partner's own app. This repository is the Swift Package Manager address of the iOS SDK and holds the sample apps for
every platform. Current release: **1.2.0**.

Overview and partner access: https://fountis.org/connect/docs

## Install

| Platform | Install |
|---|---|
| iOS | Swift Package Manager: `https://github.com/darbaz/fountis-connect`, product `FountisConnect`. iOS 15 or later. |
| Android | `org.fountis:connect:1.2.0` from Maven Central ([artifact](https://central.sonatype.com/artifact/org.fountis/connect)). |
| Flutter | `flutter pub add fountis_connect` ([pub.dev](https://pub.dev/packages/fountis_connect)). |
| React Native / Expo | `npm i @fountispanel/connect-react-native` ([npm](https://www.npmjs.com/package/@fountispanel/connect-react-native)). |
| Web | `npm i @fountispanel/connect` ([npm](https://www.npmjs.com/package/@fountispanel/connect)), or the script tag from `cdn.fountis.org`. |
| Server helper (Node) | `npm i @fountispanel/connect-server` ([npm](https://www.npmjs.com/package/@fountispanel/connect-server)). |

## iOS

In Xcode choose File > Add Package Dependencies, enter `https://github.com/darbaz/fountis-connect` and pick
`FountisConnect`. Or in your own `Package.swift`:

```swift
.package(url: "https://github.com/darbaz/fountis-connect", from: "1.2.0"),
// and on your target:
.product(name: "FountisConnect", package: "fountis-connect")
```

The SDK is a prebuilt XCFramework (`FountisConnect.xcframework.zip`, attached to each release of this repository).
Swift Package Manager downloads it and checks it against the checksum in `Package.swift`; you do not need to download
anything yourself.

```swift
import FountisConnect

// At launch (App.init or application(_:didFinishLaunchingWithOptions:)), not in a view:
FountisConnect.start(key: "pk_live_...")
FountisConnect.setUserToken { try await myServer.fountisToken() }   // nil only when nobody is signed in
FountisConnect.enableNotifications()                                // optional

let result = await FountisConnect.show()                            // .noFill, .dismissed or .completed
```

For the background check add `BGTaskSchedulerPermittedIdentifiers` = `org.fountis.connect.refresh` and the `fetch`
background mode to your Info.plist. Without them the SDK still works while the app is open.

Return `nil` from the token function only when nobody is signed in; throw when you cannot get a token. When nobody is
signed in and FOUNTIS has switched guests on for your app, the SDK offers the free studies marked open to guests.

### Guest attestation (App Attest)

FOUNTIS can ask the SDK to prove that a guest session comes from your genuine app on a genuine device. This applies to
guests only; signed-in people are not affected, and nothing is shown to the person. To support it:

1. Add the **App Attest** capability to your app target (Signing & Capabilities > + Capability > App Attest). This sets the
   entitlement `com.apple.developer.devicecheck.appattest-environment` to `production` for release builds. Xcode uses
   `development` for debug builds; FOUNTIS accepts those keys from sandbox keys (`pk_test_`) only.
2. Give FOUNTIS your Apple Team ID and bundle identifier.

There is no code to add. App Attest does not run on the iOS Simulator or on devices without it: there the SDK reports
"unsupported", and if FOUNTIS is set to enforce attestation for your app, that device is offered no guest studies.

## Samples

`samples` has a small app for each platform (iOS, Android, React Native, web) and a token endpoint for your server
(`samples/server-node`). In each folder, run `setup.sh` where there is one, or copy the `*.example.*` file, and put your
sandbox key (`pk_test_...`) in the local file it creates. Local files are git-ignored. The apps use the published
packages listed above.

## Issues

Report problems at https://github.com/darbaz/fountis-connect/issues.
