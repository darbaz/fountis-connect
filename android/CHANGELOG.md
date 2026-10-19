# Changelog

## 1.1.0 — 2026-10-19

- Guest device check with Google Play Integrity (Standard API). When FOUNTIS asks for it for your app (attestation mode `report` or `enforce`), the request for a guest session carries an integrity token, or a code saying why the device could not attest (`unsupported`, `timeout`, `error`, `no_cloud_project`). Link the FOUNTIS Google Cloud project to your app in Play Console (App integrity, Play Integrity API); FOUNTIS gives you the project number. Mode `off` (the default) never starts Play Integrity. Signed-in users are not checked. All steps share a 10 second cap. When FOUNTIS refuses the guest session (`attestation_required` or `attestation_failed`), `show()` returns `NoFill` and no guest study is offered, and the SDK does not attest or ask for a guest session again for 10 minutes. Apps installed outside Google Play keep working: the check reports that it is unavailable. New dependency `com.google.android.play:integrity:1.6.0`. New README.
- Every API request now has an overall 15 second deadline (connection, request and the whole response), the same as the Web SDK. Before, the 20 second limit applied to each read, so a server that kept sending a few bytes could keep `show()` busy for as long as it liked. When the deadline passes, `show()` ends as `NoFill` like any network failure and the next `show()` works normally. Cancelling the coroutine that called `show()` now also stops its request at once.
- The bundled survey engine now also closes on the Escape key (hardware keyboard), exactly like its x button (it asks first once something is answered).
- The bundled survey engine's "leave?" card (shown when the x is pressed after answering) now moves keyboard focus to Stay when it opens, keeps the screen behind it out of reach of Tab and screen readers (where the WebView supports `inert`), and puts focus back where it was when you stay.

## 1.0.0

First stable release of the FOUNTIS Connect Android SDK (`org.fountis:connect`).

- Shows a short FOUNTIS study teaser to partner users who match, and runs the study inside the partner app or site.
- Matching happens on the device from partner-signed user attributes. People are never linked to a FOUNTIS panelist account.
- Public API with the same names on every platform: `start`, `setUserToken`, `enableNotifications`, `show`, `setUserConsent`, `signOut`, `onEvent`.
- Studies run in the bundled FOUNTIS survey engine, localized in English, Sorani Kurdish, Bahdini Kurdish and Arabic (right-to-left supported).
- Failures are silent: the SDK never throws into the host app and reports `noFill` instead.
- Sandbox keys (`pk_test_`) accept unsigned tokens so you can try the SDK before your server signs tokens.
- Kotlin library, minSdk 23. The survey opens full screen in `FountisSurveyActivity`.
- Background refresh through WorkManager and at most one notification a day, with quiet hours from the app configuration.
- `handlePush` recognises FOUNTIS pushes.
- A token provider that throws, or does not answer within 10 seconds, shows nothing (`NoFill`) and is never treated as signed out. Return `null` only when nobody is signed in; an empty string is not signed out.
