# Changelog

## Unreleased

- Docs: the Android minimum now names Android System WebView 88 or later next to minSdk 23 (on an older WebView `show()` returns `noFill`).
- On web, the Web SDK this plugin loads now gives the study screen its own close button and a load timeout (see the Web SDK changelog).

## 1.0.0

First stable release of `fountis_connect`.

- Shows a short FOUNTIS study teaser to partner users who match, and runs the study inside the partner app or site.
- Matching happens on the device from partner-signed user attributes. People are never linked to a FOUNTIS panelist account.
- Public API with the same names on every platform: `start`, `setUserToken`, `enableNotifications`, `show`, `setUserConsent`, `signOut`, `onEvent`.
- Studies run in the bundled FOUNTIS survey engine, localized in English, Sorani Kurdish, Bahdini Kurdish and Arabic (right-to-left supported).
- Failures are silent: the SDK never throws into the host app and reports `noFill` instead.
- Sandbox keys (`pk_test_`) accept unsigned tokens so you can try the SDK before your server signs tokens.
- Federated Flutter plugin for Android, iOS and web. This is the package your app depends on.
- Includes a runnable `example/`.
- `setUserToken`: return null only when nobody is signed in; throw when you cannot get a token (nothing is shown, and the person is never treated as a guest).
- Background checks that run while Dart is not running now get no token answer and show nothing. Before, they timed out to null and could offer guest studies.
