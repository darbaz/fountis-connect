# FOUNTIS Connect

FOUNTIS Connect is an SDK that lets partner apps and websites show FOUNTIS research studies to matching users, inside
the partner's own app. This repository holds the public SDK sources. Current release: **1.1.0**.

| Platform | Install | Source |
|---|---|---|
| iOS (Swift Package Manager) | `https://github.com/darbaz/fountis-connect`, product `FountisConnect`, iOS 15+ | [ios](ios) |
| Android (Kotlin) | `org.fountis:connect:1.1.0` on Maven Central | [android](android) |
| Flutter | `flutter pub add fountis_connect` | [flutter](flutter) |
| React Native / Expo | `npm i @fountispanel/connect-react-native` | [react-native](react-native) |
| Web | `npm i @fountispanel/connect`, or a script tag from the CDN | [web](web) |
| Server helper (Node) | `npm i @fountispanel/connect-server` | [server/node](server/node) |

Packages are published to their registries when a release is cut; until then, use a tagged release of this repository
(Swift) or build from source.

## Swift Package Manager

In Xcode choose File > Add Package Dependencies and enter `https://github.com/darbaz/fountis-connect`, or in `Package.swift`:

```swift
.package(url: "https://github.com/darbaz/fountis-connect", from: "1.1.0"),
// and on your target:
.product(name: "FountisConnect", package: "fountis-connect")
```

The package manifest is `Package.swift` at the repository root; its sources live in `ios/`.

## Layout

- `ios`, `android`, `flutter`, `react-native`, `web`: the client SDKs. Each folder has its own README, LICENSE and CHANGELOG.
- `server/node`: the partner-server helper (webhook signature check, server API client).
- `samples`: small apps for each platform. Copy the `*.example.*` config, or run the platform's `setup.sh`, and put your
  sandbox key (`pk_test_...`) in the local file it creates. Local files are git-ignored.
- `i18n`: the translation strings (English, Arabic, Kurdish Sorani and Bahdini).

## Issues

Report problems at https://github.com/darbaz/fountis-connect/issues.
