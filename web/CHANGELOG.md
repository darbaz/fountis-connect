# Changelog

## 1.1.0 — 2026-10-19

- npm package renamed to `@fountispanel/connect`. Nothing else changes; install and import it under the new name.
- The study screen can always be left. It now has its own close button outside the iframe (labelled in the study's language, focused when the screen opens) and handles Escape on the host page, so a study page that is still loading, or never loads, no longer leaves the person stuck. The engine's own close button takes over once the page is up.
- That button is drawn exactly like the engine's (start side of the same centred bar, 4 px from the top, bare 20 px icon, 44 px target, visible focus ring), so nothing jumps when the engine takes over. Until the engine is up, Tab and Shift+Tab stay on it instead of walking into the page behind, and the study frame is `aria-busy` with a hidden "Loading…" line (next to it, not inside it) for screen readers. Once the study is up, focus can no longer wander onto the page behind it: Tab past the study's last control, or Shift+Tab before its first, goes back into the study.
- The survey page itself (`engine.html`, served by FOUNTIS) now shows its close button from its first paint, also while it waits for the study to start; every request it makes ends after 15 seconds in total (a stalled start shows its error screen with a Close action); and Escape closes it like its x button does (it asks first once something is answered).
- A study page that does not load within 15 seconds closes itself and `show()` returns `noFill`. The study is neither marked taken nor dismissed (so it is offered again next time) and no `dismissed` event is sent. Closing the screen yourself while it loads is an ordinary dismissal.
- When the study screen closes, keyboard focus returns to the element that had it before the teaser appeared.
- The study page keeps clear of a notch: the SDK measures the page's `env(safe-area-inset-*)` once when the study starts and sends it to the survey page (which cannot read it inside an iframe), so on a phone in landscape the header and close button no longer sit under the notch when your page uses `viewport-fit=cover`. Nothing to configure.
- Rotating the phone (or resizing the window) while a study is open now re-measures the page's safe-area insets and sends just the new numbers to the survey page (at most once per 150 ms, only when they changed), so the header stays clear of the notch after a rotation. The listeners are removed when the study closes.
- The survey page's "leave?" card (shown when the x is pressed after answering) now moves keyboard focus to Stay when it opens, keeps the screen behind it out of the tab order, and puts focus back where it was when you stay.

## 1.0.0

First stable release of `@fountispanel/connect` (Web SDK).

- Shows a short FOUNTIS study teaser to partner users who match, and runs the study inside the partner app or site.
- Matching happens on the device from partner-signed user attributes. People are never linked to a FOUNTIS panelist account.
- Public API with the same names on every platform: `start`, `setUserToken`, `enableNotifications`, `show`, `setUserConsent`, `signOut`, `onEvent`.
- Studies run in the bundled FOUNTIS survey engine, localized in English, Sorani Kurdish, Bahdini Kurdish and Arabic (right-to-left supported).
- Failures are silent: the SDK never throws into the host app and reports `noFill` instead.
- Sandbox keys (`pk_test_`) accept unsigned tokens so you can try the SDK before your server signs tokens.
- Ships as an ES module, a CommonJS module with TypeScript types, and a single minified `connect.js` browser bundle (global `FountisConnect`) for a script tag with SRI.
- `enableNotifications()` turns on an in-page invitation after page load (the web has no push).
- A token function that throws or rejects, or does not answer within 10 seconds, shows nothing (`noFill`) instead of locking the SDK, and is never treated as signed out. Only `null` or `undefined` means nobody is signed in; an empty string is not signed out.
- An API request that does not finish within 15 seconds (response body included) is aborted and shows nothing (`noFill`), so a stalled network request can no longer make every later `show()` return `noFill` until the page reloads.
