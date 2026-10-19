# Changelog

## 1.1.0 — 2026-10-19

- Android: guest device check with Google Play Integrity when FOUNTIS asks for it for your app (see the Android SDK changelog). The Android build now depends on `com.google.android.play:integrity:1.6.0`. Link the FOUNTIS Google Cloud project to your app in Play Console (App integrity, Play Integrity API).
- iOS: guest device attestation with App Attest, from the bundled iOS SDK (see its changelog). If FOUNTIS asks for it on your guests, add the App Attest capability to the iOS app (entitlement `com.apple.developer.devicecheck.appattest-environment`; in Expo `ios.entitlements`). Nothing changes when attestation is off.
- npm package renamed to `@fountispanel/connect-react-native`. Nothing else changes; install and import it under the new name.
- Android: every API request now has an overall 15 second deadline (connection, request and the whole response), the same as the Web SDK, so a server that keeps sending a few bytes cannot keep `show()` busy. The failure ends as `noFill` like any network error. This comes from the bundled Android SDK (see its changelog).
- Docs: the Android minimum now names Android System WebView 88 or later next to API 23 (on an older WebView `show()` returns `noFill`), and the README token example reads the `{ "token": "..." }` reply of the sample server, treating a reply without a token as a failure.
- On React Native Web, the Web SDK it wraps now gives the study screen its own close button and a load timeout (see the Web SDK changelog).
- iOS: every API request now ends after 15 s in total, including a slowly trickling response body (was 30 s); the call fails as `noFill`.
- The bundled survey engine now also closes on the Escape key (hardware keyboard), exactly like its x button (it asks first once something is answered).
- The bundled survey engine's "leave?" card (shown when the x is pressed after answering) now moves keyboard focus to Stay when it opens, keeps the screen behind it out of reach of Tab and screen readers (where the WebView supports `inert`), and puts focus back where it was when you stay.

## 1.0.0

First stable release of `@fountispanel/connect-react-native`.

- Shows a short FOUNTIS study teaser to partner users who match, and runs the study inside the partner app or site.
- Matching happens on the device from partner-signed user attributes. People are never linked to a FOUNTIS panelist account.
- Public API with the same names on every platform: `start`, `setUserToken`, `enableNotifications`, `show`, `setUserConsent`, `signOut`, `onEvent`.
- Studies run in the bundled FOUNTIS survey engine, localized in English, Sorani Kurdish, Bahdini Kurdish and Arabic (right-to-left supported).
- Failures are silent: the SDK never throws into the host app and reports `noFill` instead.
- Sandbox keys (`pk_test_`) accept unsigned tokens so you can try the SDK before your server signs tokens.
- React Native and Expo (development builds, not Expo Go): wraps the native iOS and Android SDKs.
- Expo config plugin adds the iOS background mode and task id, and the publishable key.
- On React Native Web it wraps the Web SDK `@fountispanel/connect`.
- A token function that throws or rejects (on iOS and Android also one that does not answer within 10 seconds) now shows nothing (`noFill`) instead of being treated as signed out, so a signed-in person is never offered guest studies. Return `null` only when nobody is signed in.
- Background checks that run while JavaScript is not running now get no token answer and show nothing. Before, they timed out to `null` and could offer guest studies.
