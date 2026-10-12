# Sample token endpoint (no framework)

`GET /fountis/token` returns `{ token }` for the signed-in user; `POST /fountis/webhook` verifies and logs FOUNTIS webhooks.

```bash
npm install
FOUNTIS_APP_ID=app_… FOUNTIS_PARTNER_ID=ptn_… FOUNTIS_USER_SECRET=$(openssl rand -hex 32) npm start
```

Without `FOUNTIS_SIGNING_KEY` it issues unsigned sandbox tokens (works only with `pk_test_` keys). Then, in the page:

```js
// null only when signed out (401); a failed request or a response without a token throws (nothing is shown)
FountisConnect.setUserToken(async () => {
  const r = await fetch("/fountis/token");
  if (r.status === 401) return null;                  // nobody is signed in
  if (!r.ok) throw new Error("token request failed"); // nothing is shown
  const { token } = await r.json();
  if (!token) throw new Error("no token in response");
  return token;
});
```
