# Changelog

## 1.1.0 — 2026-10-19

- Guest device attestation with App Attest. When FOUNTIS has attestation switched on for your app, the SDK registers an App Attest key once per install and sends an assertion with each new guest session. Where App Attest is not available (the Simulator, old devices) it says so, and all attestation steps share a 10 second cap. If an app that enforces attestation is refused, `show()` returns `noFill` and no guest studies are offered. People with a signed token are not affected, and an app with attestation off never contacts the attestation endpoints. To use it, add the App Attest capability to your app (entitlement `com.apple.developer.devicecheck.appattest-environment`); see the README.
- Every API request now has a 15 second deadline in total, covering the connection, the request and the whole response body (it used to be 15 seconds idle and 30 seconds in total). A server that keeps sending a byte now and then can no longer hold a request open. When the deadline passes the request fails like any other timeout, so `show()` returns `noFill` and events are dropped silently. The 10 second waits for the token provider and for the survey to appear are unchanged.
- The bundled survey engine now also closes on the Escape key (hardware keyboard), exactly like its x button (it asks first once something is answered).
- The bundled survey engine's "leave?" card (shown when the x is pressed after answering) now moves keyboard focus to Stay when it opens, keeps the screen behind it out of reach of Tab and screen readers (where the WebView supports `inert`), and puts focus back where it was when you stay.

## 1.0.0

First stable release of the FOUNTIS Connect iOS SDK (Swift package `FountisConnect`).

- Shows a short FOUNTIS study teaser to partner users who match, and runs the study inside the partner app or site.
- Matching happens on the device from partner-signed user attributes. People are never linked to a FOUNTIS panelist account.
- Public API with the same names on every platform: `start`, `setUserToken`, `enableNotifications`, `show`, `setUserConsent`, `signOut`, `onEvent`.
- Studies run in the bundled FOUNTIS survey engine, localized in English, Sorani Kurdish, Bahdini Kurdish and Arabic (right-to-left supported).
- Failures are silent: the SDK never throws into the host app and reports `noFill` instead.
- Sandbox keys (`pk_test_`) accept unsigned tokens so you can try the SDK before your server signs tokens.
- Swift package, iOS 15 or later. The survey opens full screen in native code.
- Background refresh through BGTaskScheduler and at most one notification a day.
- `handlePush` and `handleNotificationResponse` recognise FOUNTIS notifications.
- Includes a privacy manifest (`PrivacyInfo.xcprivacy`).
- A token provider that throws, or does not answer within 10 seconds, shows nothing (`noFill`) and is never treated as signed out. Return `nil` only when nobody is signed in; an empty string is not signed out.
- If iOS never starts showing the survey (for example, the top screen is not in a window), `show()` returns `noFill` after 10 seconds instead of ignoring every later call, and `shown` is reported only when the survey really appears.
