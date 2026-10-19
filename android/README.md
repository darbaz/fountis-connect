# FOUNTIS Connect for Android

`org.fountis:connect` is the Kotlin library (minSdk 23, Android System WebView 88 or later) that shows a short FOUNTIS
research study to the people in your app. Setup, the token provider, notifications and the full reference are in the
partner docs: https://fountis.org/connect/docs

```kotlin
// In Application.onCreate:
FountisConnect.start(this, "pk_live_...")
FountisConnect.setUserToken { myServer.fountisToken() }   // null when nobody is signed in
```

## Guest studies and the device check (Google Play Integrity)

People with no signed token (the provider returned `null`) are guests. FOUNTIS can ask that a guest's device is checked
before it hands out a guest session. The SDK then asks Google Play Integrity (Standard API) to vouch for the device and
for your app, and sends the result with the request for the guest session. Nothing is shown to the person and there is
nothing to call.

- **Signed-in users are not checked.** Your signed token already vouches for them.
- **Set-up in Play Console (once per app).** Link the FOUNTIS Google Cloud project to your app: Play Console, your app,
  App integrity, Play Integrity API, Link a Cloud project. FOUNTIS gives you the project number, and sets the same number
  on your app in the FOUNTIS console. Use that project, not one of your own. Until it is linked, the check reports
  "unavailable".
- **Modes.** FOUNTIS sets the mode per app. `off` (the default): the device is not checked and Google Play Integrity is
  never started. `report`: the device is checked and FOUNTIS records the outcome; guests still get studies. `enforce`:
  a guest gets studies only when the check passes; otherwise `show()` returns `NoFill`, like any other failure.
- **Apps installed outside Google Play** (a sideloaded APK, a store without Play services) work as before. The check
  reports that it is unavailable; in `enforce` mode that means no guest studies for those installs.
- **Dependency.** `com.google.android.play:integrity` comes with the SDK. There is no extra Gradle line, permission or
  manifest entry. If your app still depends on the retired `com.google.android.play:core` library, replace it with the
  split Play libraries (it conflicts with `com.google.android.play:core-common`, which Play Integrity uses).

Like every other failure, a refused or failed check is silent: the SDK never throws into your app and writes one debug
line with the Logcat tag `FountisConnect`.
