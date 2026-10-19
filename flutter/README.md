# FOUNTIS Connect for Flutter (repository notes)

The package your app depends on is `fountis_connect`; its README is [fountis_connect/README.md](fountis_connect/README.md).
It is a federated plugin made of four packages:

| Package | What it is |
|---|---|
| `fountis_connect` | The one you depend on (app-facing API and `example/`). |
| `fountis_connect_platform_interface` | The shared interface, plus the MethodChannel client used by iOS and Android. |
| `fountis_connect_mobile` | iOS (Swift) and Android (Kotlin) code. One package for both platforms. |
| `fountis_connect_web` | Web implementation (wraps `connect.js`). |

## In this repository

The native SDKs live in `../ios` and `../android`. The podspec copies the Swift sources into
`fountis_connect_mobile/ios/FountisConnectSDK` whenever CocoaPods reads it, and `android/build.gradle` reads
`../../../android/connect` in place. For pub.dev, run `sh scripts/vendor-native.sh` first, which puts real copies of
both inside the package.

The example's runner projects are generated, not committed:

```sh
cd fountis_connect/example
flutter create --platforms=android,ios,web --project-name fountis_connect_example .
flutter run
```

CI (`.github/workflows/connect-flutter.yml`) analyzes the packages and builds the example for Android, web and the iOS simulator.
The packages depend on each other by hosted version (`^1.1.0`, as pub.dev requires). Each `pubspec_overrides.yaml`
points those dependencies at the sibling folders, so everything resolves locally; pub ignores that file when publishing.
Publishing order is platform_interface, then mobile and web, then `fountis_connect`.
