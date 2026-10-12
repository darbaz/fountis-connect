# @fountispanel/connect-server

Server helper for FOUNTIS Connect partners (Node 18+, ESM). Three things:

1. sign a **user token** for your logged-in, verified user;
2. **verify webhooks** FOUNTIS sends you;
3. **check** a token from the command line.

```bash
npm i @fountispanel/connect-server
```

## 1. Sign a user token

Your app calls this from your own login-protected endpoint. The web/iOS SDK asks that endpoint for a token whenever it needs one.

```js
import { createUserToken } from "@fountispanel/connect-server";

const token = await createUserToken({
  appId: "app_…",              // from the FOUNTIS partner console
  partnerId: "ptn_…",
  kid: "my-key-1",             // matches the public JWK you gave FOUNTIS
  signingKey: process.env.FOUNTIS_SIGNING_KEY,   // PEM, PKCS#8, ES256 (P-256)
  userSecret: process.env.FOUNTIS_USER_SECRET,   // any long random string, keep it private and stable
  mapping,                     // your approved attribute mapping (below)
  user,                        // your user record; user.id is required
  lang: "ku",                  // optional: en | ku | kmr | ar
});
```

- `sub` = `base64url(HMAC-SHA256(userSecret, String(user.id)))`. FOUNTIS never sees your user id. Do not change `userSecret` later: it would make every user look new.
- Tokens last 1 hour by default (`ttlSeconds`, max 24 h). Create one per request; do not store them.
- Users under 18 are refused (`error.code === "not_adult"`): return no token for them.
- Only send users you have verified yourself. The token says `kyc: "verified"`.

### Mapping

The mapping says which of your fields become FOUNTIS attributes. Only these attributes exist: `gender` (`female` | `male`), `birth_year`, `governorate`, `city`, `lang`. FOUNTIS approves your mapping in the console; use the same one here.

```js
const mapping = {
  version: 1,
  attributes: {
    gender:     { field: "sex",  values: { M: "male", F: "female" } },
    birth_year: { field: "dob",  transform: "year" },       // Date, ISO string or a year number
    city:       { field: "address.city_code", values: { ERB: "erbil", SUL: "sulaymaniyah" } },
  },
};
```

A value that is missing or not in `values` is left out; nothing is guessed. `governorate` and `city` must be FOUNTIS location codes (lower case, for example `erbil`; the full lists are in the protocol contract): a value that is not one is left out too, so one unmapped city never costs the user their token.

### Sandbox without a key pair

With a `pk_test_` key, FOUNTIS also accepts an unsigned token:

```js
import { createUnsignedToken } from "@fountispanel/connect-server";
const token = createUnsignedToken({ appId, partnerId, userSecret, mapping, user });
```

## 2. Verify webhooks

FOUNTIS signs every webhook: header `Fountis-Signature: t=<unix seconds>,v1=<hex>`, HMAC-SHA256 of `t + "." + rawBody`. Verify the **raw** body (before JSON parsing).

```js
import { verifyWebhook } from "@fountispanel/connect-server";

http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks);
  if (!verifyWebhook(raw, req.headers["fountis-signature"], process.env.FOUNTIS_WEBHOOK_SECRET)) {
    res.writeHead(400).end();
    return;
  }
  const event = JSON.parse(raw.toString());
  // credit event.units to the user behind event.sub …
  res.writeHead(200).end();
});
```

`verifyWebhook` returns `true` only for a correct signature that is less than 5 minutes old (constant-time compare; several `v1=` values are accepted during secret rotation). To map `event.sub` back to your user, compute `subjectFor(userSecret, user.id)` for your users (or keep the sub next to the user row).

## 3. Check a token

```bash
npx @fountispanel/connect-server check <token>
npx @fountispanel/connect-server check <token> --jwk public-jwk.json   # also verifies the signature
```

Prints the decoded header and claims and lists problems: unexpected claims, wrong `aud`, a numeric `sub`, a lifetime over 24 h, a bad attribute value.

## Test

```bash
npm test
```
