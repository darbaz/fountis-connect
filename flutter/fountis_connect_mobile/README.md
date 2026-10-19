# fountis_connect_mobile

The iOS and Android implementation of the [`fountis_connect`](https://pub.dev/packages/fountis_connect) plugin
(FOUNTIS Connect for Flutter). It wraps the native FOUNTIS Connect SDKs (Swift for iOS 15+, Kotlin for Android minSdk 23 with Android System WebView 88 or later)
and carries a copy of their sources.

You do not depend on this package directly. Add `fountis_connect` to your app instead.

Android guests (no token): when FOUNTIS asks for it, the device is checked with Google Play Integrity before the guest session starts. Link the FOUNTIS Google Cloud project to your app in Play Console (App integrity, Play Integrity API); FOUNTIS gives you the project number. Nothing to call, and signed-in users are not checked.
