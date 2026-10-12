# Changelog

## Unreleased

- Android: every API request now has an overall 15 second deadline (connection, request and the whole response), the same as the Web SDK, so a server that keeps sending a few bytes cannot keep `show()` busy. The failure ends as `noFill` like any network error. This comes from the bundled Android SDK (see its changelog).
- iOS: every API request now ends after 15 s in total, including a slowly trickling response body (was 30 s); the call fails as `noFill`.
- The bundled survey engine now also closes on the Escape key (hardware keyboard), exactly like its x button (it asks first once something is answered).
- The bundled survey engine's "leave?" card (shown when the x is pressed after answering) now moves keyboard focus to Stay when it opens, keeps the screen behind it out of reach of Tab and screen readers (where the WebView supports `inert`), and puts focus back where it was when you stay.

## 1.0.0

First stable release of `fountis_connect_mobile`.

- iOS (Swift) and Android (Kotlin) implementation of `fountis_connect`. Contains a copy of the native FOUNTIS Connect SDKs.
- A token request that fails (the Dart provider threw, or nothing answered within 10 seconds) now reaches the native SDK as an error, so nothing is shown, instead of as a null token, which meant "nobody is signed in" (the guest path).
