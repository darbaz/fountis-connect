# Changelog

## 1.1.0 — 2026-10-19

- npm package renamed to `@fountispanel/connect-server`. Nothing else changes; install and import it under the new name.
- `applyMapping` leaves out a `governorate` or `city` that is not a FOUNTIS location code (lower-case code such as `erbil`), also when the rule has no `values` table; FOUNTIS refuses such values with `422 invalid_attribute`, so one unmapped city no longer costs the user their token.
- `checkToken` reports a `governorate` or `city` that is not a FOUNTIS location code.

## 1.0.0

First stable release of `@fountispanel/connect-server` (Node server helper).

- `createUserToken`: signs the ES256 user token for a logged-in, verified user, applying your approved attribute mapping.
- `createUnsignedToken`: unsigned tokens for sandbox use.
- `verifyWebhook`: checks the signature and timestamp of webhooks FOUNTIS sends you.
- `checkToken` and the `connect-server` command line tool for inspecting a token.
- Node 18 or later, ESM, one dependency (`jose`).
