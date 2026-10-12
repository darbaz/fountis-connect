# @fountispanel/connect

FOUNTIS Connect web SDK. Shows your matching users a short study teaser and runs the study in a modal on your page.

Source and docs: https://github.com/darbaz/fountis-connect

## Install

```sh
npm i @fountispanel/connect
```

```js
import * as FountisConnect from "@fountispanel/connect";

FountisConnect.start({ key: "pk_live_..." });
FountisConnect.setUserToken(async () => await myServer.fountisToken()); // null only when nobody is signed in; throw if the request fails (nothing is shown)
FountisConnect.enableNotifications(); // in-page invitation after page load
```

Or load the browser bundle with a script tag (use the SRI hash printed by the release):

```html
<script src="https://cdn.fountis.org/connect/1.0.0/connect.js" integrity="sha384-..." crossorigin="anonymous"></script>
```

The API has the same names as the native SDKs: `start`, `setUserToken`, `enableNotifications`, `show`,
`setUserConsent`, `signOut`, `onEvent`. Every failure is silent and becomes `noFill`.

The token is signed by your own server, see `@fountispanel/connect-server`.
