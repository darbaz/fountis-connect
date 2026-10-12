# FOUNTIS Connect for React Native and Expo

`@fountispanel/connect-react-native` shows FOUNTIS studies to the people in your app. On iOS and Android it wraps the
native FOUNTIS Connect SDKs (the survey opens full screen, in native code). On React Native Web it wraps the Web SDK
`@fountispanel/connect`. The API has the same names everywhere.

It needs native code, so use an **Expo development build** (or a bare React Native app). It does **not** run in Expo Go.

Minimums: iOS 15.1, and on Android 6.0 (API 23) with Android System WebView 88 or later. On an older WebView `show()` returns `noFill`.

## Install

```sh
npx expo install @fountispanel/connect-react-native
```

Add the config plugin to `app.json` (or `app.config.js`):

```json
{
  "expo": {
    "plugins": [["@fountispanel/connect-react-native", { "key": "pk_live_..." }]]
  }
}
```

The plugin adds the iOS `fetch` background mode and the `org.fountis.connect.refresh` background task id, and writes
your publishable key (`pk_...`, safe to ship) so the SDK can start while the app launches. That early start is what
lets iOS run the background check. Then rebuild: `npx expo prebuild` and `npx expo run:ios` / `run:android`
(or a new EAS development build).

Bare React Native: run `npx pod-install`, and add the same two Info.plist entries yourself
(`UIBackgroundModes` = `fetch`, `BGTaskSchedulerPermittedIdentifiers` = `org.fountis.connect.refresh`).
Without them the SDK still works while the app is open; only the background check is off.

## Use

```ts
import * as Fountis from '@fountispanel/connect-react-native';

Fountis.start({ key: 'pk_live_...' });          // safe to call again; the plugin may already have started it
Fountis.setUserToken(async () => {
  const r = await fetch('https://your-server.example/fountis/token', { credentials: 'include' });
  if (r.status === 401) return null;             // null only when nobody is signed in (here: your endpoint answers 401)
  if (!r.ok) throw new Error('token request failed');   // a failed request is not "signed out": throw
  const { token } = await r.json();              // your endpoint answers { "token": "..." } (see samples/server-node)
  if (!token) throw new Error('no token in response');  // a reply without a token is a failure, not "signed out"
  return token;
});
Fountis.enableNotifications();                   // optional: one local notification a day at most

const result = await Fountis.show();             // 'noFill' | 'dismissed' | 'completed'
const off = Fountis.onEvent((e) => console.log(e.type, e.offerId));   // shown, dismissed, completed, noFill, notified
```

| Call | What it does |
|---|---|
| `start({ key, apiBase? })` | Starts the SDK. `apiBase` is only for testing against another backend. |
| `setUserToken(fn)` | `fn` returns the token signed by **your server** (see `@fountispanel/connect-server`), or `null` when nobody is signed in, and throws when it cannot get a token. It is called when the SDK needs a token; it is not stored. |
| `enableNotifications()` | Turns on the background check and asks for the notification permission. |
| `show()` | Looks for a matching study and shows it. `noFill` comes back fast when there is none. |
| `handlePush(data)` | Call from your push handler. Resolves `true` if it was a FOUNTIS push (has a `fountis` key). |
| `setUserConsent(bool)` | Your own consent switch. Default `true`. |
| `signOut()` | Forgets the person on this device. |
| `onEvent(fn)` | Anonymous events, no titles or answers. Returns a function that removes the listener. |

Every failure is silent and becomes `noFill`. The SDK never throws into your app.

The token function has four outcomes:

- It returns a token: the person is signed in and sees the studies that match them.
- It returns `null` (or `undefined`): nobody is signed in. The SDK offers guest studies if your app allows guests.
- It throws or rejects: nothing is shown (`noFill`), and the person is never treated as a guest. No answer within 10 seconds also counts as a failure.
- An empty string is not "signed out": nothing is shown.

Notes:

- The token function runs in JavaScript. A background check that wakes the app without JavaScript running gets no answer
  and does nothing; checks work while the app is open or recently used, and the study also appears on app open.
- **Guests:** when the token function returns `null` and FOUNTIS has switched guests on for your app (adult-only apps only), the SDK offers the free studies marked open to guests, after an 18+ confirmation. There is nothing to call; an app without accounts can pass `setUserToken(() => null)`. Guests never see a reward. If your token request fails, throw instead of returning `null`, so a signed-in person is not shown guest studies.
- On the web, `enableNotifications()` turns on the in-page invitation, and `handlePush` always resolves `false`.
- `start` also takes `engineUrl` on the web, to point at another hosted engine.

## In this repository

The native SDKs live in `../ios` and `../android`. The podspec copies the Swift sources into `ios/FountisConnectSDK`
when `pod install` runs (re-run it after changing the SDK), and `android/build.gradle` reads `../../android/connect`
in place. `npm pack` copies both into the package (`scripts/vendor-native.sh`), so the tarball is self-contained.

Sample app: `../samples/react-native` (`npm install && npx expo prebuild && npx expo run:ios`).
`npm run typecheck` checks the TypeScript.
