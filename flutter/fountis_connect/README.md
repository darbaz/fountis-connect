# FOUNTIS Connect for Flutter

`fountis_connect` shows FOUNTIS studies to the people in your app. On iOS and Android it wraps the native FOUNTIS
Connect SDKs (the survey opens full screen in native code, so there is no platform view). On the web it wraps the Web
SDK through `dart:js_interop`. The API has the same names as every other FOUNTIS Connect SDK.

| Package | What it is |
|---|---|
| `fountis_connect` | The one you depend on (app-facing API and `example/`). |
| `fountis_connect_platform_interface` | The shared interface, plus the MethodChannel client used by iOS and Android. |
| `fountis_connect_mobile` | iOS (Swift) and Android (Kotlin) code. One package for both platforms. |
| `fountis_connect_web` | Web implementation (wraps `connect.js`). |

## Set up

```yaml
dependencies:
  fountis_connect: ^1.1.0
```

**iOS** (15 or later). In `Info.plist` add:

```xml
<key>UIBackgroundModes</key><array><string>fetch</string></array>
<key>BGTaskSchedulerPermittedIdentifiers</key><array><string>org.fountis.connect.refresh</string></array>
<key>FountisConnectKey</key><string>pk_live_...</string>
```

The first two are for the background check (optional). `FountisConnectKey` (your publishable key, safe to ship) lets the
SDK start while the app launches, which iOS requires for background checks. Without the key, `start()` from Dart still
works while the app is open.

If FOUNTIS asks for device attestation on your guests, add the **App Attest** capability to the Runner target in Xcode (entitlement `com.apple.developer.devicecheck.appattest-environment` = `production`); there is nothing to call from Dart.

**Android** (minSdk 23, and Android System WebView 88 or later: on an older WebView `show()` returns `noFill`). Nothing to add: the permissions and the survey screen come with the plugin. Optionally add
`<meta-data android:name="org.fountis.connect.KEY" android:value="pk_live_..."/>` to start the SDK with the engine.

**Web.** Add the script to `web/index.html` (the plugin loads it for you if you forget):

```html
<script src="https://cdn.fountis.org/connect/1.1.0/connect.js"></script>
```

## Use

```dart
import 'package:fountis_connect/fountis_connect.dart';

await FountisConnect.start(key: 'pk_live_...');
FountisConnect.setUserToken(() async => await myServer.fountisToken()); // null only when nobody is signed in
await FountisConnect.enableNotifications();   // optional: one notification a day at most

final result = await FountisConnect.show();   // FountisResult.noFill / dismissed / completed
FountisConnect.onEvent.listen((e) => print('${e.type} ${e.offerId}')); // shown, dismissed, completed, noFill, notified
```

`handlePush(Map data)` returns true when a push belongs to FOUNTIS (it has a `fountis` key), `setUserConsent(bool)` is
your own consent switch, `signOut()` forgets the person on this device. The token comes from **your server**
(see `@fountispanel/connect-server`). Every failure is silent and becomes `noFill`.

Return `null` from the token function only when nobody is signed in (that is the guest path, when your app allows
guests). If the token request fails, let it throw: nothing is shown, and a signed-in person is never treated as a
guest. No answer within 10 seconds also counts as a failure. An empty string is not "signed out": nothing is shown.

The token function runs in Dart, so a background check that wakes the app without Flutter running finds no token and does
nothing. Checks work while the app is open or recently used, and the study also appears on app open.
