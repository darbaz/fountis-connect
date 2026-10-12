import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { SignJWT, importPKCS8 } from "jose";

/** Error with a stable `code`, so callers can branch without parsing messages. */
export class ConnectTokenError extends Error {
  constructor(code, message) {
    super(message || code);
    this.code = code;
    this.name = "ConnectTokenError";
  }
}

const b64url = (buf) => Buffer.from(buf).toString("base64url");

/** sub = base64url(HMAC-SHA256(userSecret, String(user.id))). Stable per user, not reversible without the secret. */
export function subjectFor(userSecret, userId) {
  if (!userSecret) throw new ConnectTokenError("missing_user_secret");
  if (userId === undefined || userId === null || userId === "") throw new ConnectTokenError("missing_user_id");
  return b64url(createHmac("sha256", userSecret).update(String(userId)).digest());
}

const getPath = (obj, path) => String(path).split(".").reduce((o, k) => (o == null ? undefined : o[k]), obj);

/**
 * `governorate` and `city` are FOUNTIS location codes (lower case, e.g. "erbil"; the lists are in
 * protocol/CONTRACT.md), never names, phone numbers or your own codes. This is the shape FOUNTIS
 * accepts at the edge (up to 3 digits); the exact list is checked server-side.
 */
const isLocationCode = (v) => typeof v === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(v) && (v.match(/\d/g) || []).length <= 3;

function toYear(v) {
  if (typeof v === "number" && Number.isInteger(v) && v >= 1900 && v <= 2200) return v;
  if (v instanceof Date && !Number.isNaN(v.getTime())) return v.getUTCFullYear();
  if (typeof v === "string") {
    if (/^\d{4}$/.test(v.trim())) return Number(v);
    const d = new Date(v);
    if (!Number.isNaN(d.getTime())) return d.getUTCFullYear();
  }
  return undefined;
}

/**
 * Apply the partner's approved mapping spec to a user record. Returns the attrs claim.
 *   mapping = { version?, attributes: { gender: { field: "sex", values: { M: "male", F: "female" } },
 *                                       birth_year: { field: "dob", transform: "year" },
 *                                       city: { field: "city_code", values: { ... } } } }
 * Attributes whose value is missing or not in `values` are left out (never guessed). So is a
 * `governorate` / `city` that is not a FOUNTIS location code (see isLocationCode): one unmapped
 * city must not make FOUNTIS refuse the whole token.
 */
export function applyMapping(mapping, user) {
  const out = {};
  for (const [attr, rule] of Object.entries(mapping?.attributes ?? {})) {
    let v = getPath(user, rule.field ?? attr);
    if (v === undefined || v === null || v === "") continue;
    if (rule.values) {
      v = rule.values[String(v)];
      if (v === undefined) continue;
    }
    if (rule.transform === "year") {
      v = toYear(v);
      if (v === undefined) continue;
    } else if (rule.transform) {
      throw new ConnectTokenError("bad_mapping", `unknown transform "${rule.transform}"`);
    }
    if ((attr === "governorate" || attr === "city") && !isLocationCode(v)) continue;
    out[attr] = v;
  }
  return out;
}

function buildClaims({ appId, partnerId, userSecret, mapping, user, lang, ttlSeconds = 3600, now = Date.now() }) {
  if (!appId || !partnerId) throw new ConnectTokenError("missing_ids", "appId and partnerId are required");
  if (!user) throw new ConnectTokenError("missing_user");
  const attrs = applyMapping(mapping, user);
  if (lang) attrs.lang = lang;
  const year = new Date(now).getUTCFullYear();
  if (attrs.birth_year !== undefined && attrs.birth_year > year - 18)
    throw new ConnectTokenError("not_adult", "FOUNTIS studies are for adults (18+)");
  const iat = Math.floor(now / 1000);
  const ttl = Math.min(Math.max(Math.floor(ttlSeconds), 60), 86400);
  return {
    iss: partnerId,
    aud: `fountis-connect:${appId}`,
    sub: subjectFor(userSecret, user.id),
    kyc: "verified",
    attrs,
    mapping_version: mapping?.version ?? mapping?.mapping_version ?? 1,
    iat,
    exp: iat + ttl,
    jti: b64url(randomBytes(16)),
  };
}

/**
 * Sign a user token (JWS ES256) for the FOUNTIS Connect SDK.
 * signingKey is the PEM (PKCS#8) private key whose public JWK you gave FOUNTIS.
 * Only call this for users YOU have verified (kyc: "verified"), after your own login check.
 */
export async function createUserToken({ signingKey, kid, ...rest }) {
  if (!signingKey) throw new ConnectTokenError("missing_signing_key");
  const claims = buildClaims(rest);
  const key = await importPKCS8(signingKey, "ES256");
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "ES256", typ: "JWT", kid: kid ?? rest.appId })
    .sign(key);
}

/** Sandbox only: an unsigned token (alg "none"). The server accepts it just for pk_test_ keys. */
export function createUnsignedToken(opts) {
  const claims = buildClaims(opts);
  const head = b64url(JSON.stringify({ alg: "none", typ: "JWT" }));
  return `${head}.${b64url(JSON.stringify(claims))}.`;
}

/* ------------------------------- webhooks ------------------------------- */

/** Header value for a webhook body: `t=<unix seconds>,v1=<hex hmac of "t.body">`. (FOUNTIS signs; exported for tests.) */
export function signWebhook(rawBody, secret, t = Math.floor(Date.now() / 1000)) {
  const mac = createHmac("sha256", secret).update(`${t}.${rawBody}`).digest("hex");
  return `t=${t},v1=${mac}`;
}

/**
 * Verify a FOUNTIS webhook. Pass the RAW request body (string or Buffer), the
 * `Fountis-Signature` header and your webhook secret. Returns true only for a
 * fresh (within 5 minutes), correctly signed body.
 */
export function verifyWebhook(rawBody, signatureHeader, secret, { toleranceSeconds = 300, now = Date.now() } = {}) {
  try {
    if (!signatureHeader || !secret) return false;
    const parts = String(signatureHeader).split(",").map((p) => p.trim().split("="));
    const t = Number(parts.find(([k]) => k === "t")?.[1]);
    const sigs = parts.filter(([k]) => k === "v1").map(([, v]) => v);
    if (!Number.isFinite(t) || sigs.length === 0) return false;
    if (Math.abs(now / 1000 - t) > toleranceSeconds) return false;
    const body = Buffer.isBuffer(rawBody) ? rawBody.toString("utf8") : String(rawBody);
    const expected = createHmac("sha256", secret).update(`${t}.${body}`).digest();
    return sigs.some((hex) => {
      if (!/^[0-9a-f]{64}$/i.test(hex)) return false;
      return timingSafeEqual(Buffer.from(hex, "hex"), expected);
    });
  } catch {
    return false;
  }
}

/* ------------------------------ token check ------------------------------ */

const CLAIMS = ["iss", "aud", "sub", "kyc", "attrs", "mapping_version", "iat", "exp", "jti"];
const ATTRS = {
  gender: (v) => ["female", "male"].includes(v),
  birth_year: (v, year) => Number.isInteger(v) && v <= year - 18 && v >= 1900,
  governorate: isLocationCode,
  city: isLocationCode,
  lang: (v) => ["en", "ku", "kmr", "ar"].includes(v),
};

/** Decode (no signature check) and validate the claim shape. Returns { ok, errors, header, claims }. */
export function checkToken(token, { now = Date.now() } = {}) {
  const errors = [];
  const warnings = [];
  const parts = String(token || "").trim().split(".");
  if (parts.length !== 3) return { ok: false, errors: ["not a compact JWS (needs 3 dot-separated parts)"] };
  let header, claims;
  try {
    header = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"));
    claims = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return { ok: false, errors: ["header or payload is not base64url JSON"] };
  }
  if (header.alg === "none") warnings.push("alg is none: accepted for sandbox (pk_test_) keys only");
  else if (header.alg !== "ES256") errors.push(`alg must be ES256 (got ${header.alg})`);
  else if (!header.kid) errors.push("header.kid is missing");
  for (const k of Object.keys(claims)) if (!CLAIMS.includes(k)) errors.push(`unexpected claim "${k}" (the claim set is closed)`);
  for (const k of CLAIMS) if (claims[k] === undefined) errors.push(`missing claim "${k}"`);
  const year = new Date(now).getUTCFullYear();
  if (typeof claims.iss !== "string" || !claims.iss) errors.push("iss must be your partner id");
  if (typeof claims.aud !== "string" || !claims.aud.startsWith("fountis-connect:app_")) errors.push('aud must be "fountis-connect:<app id>"');
  if (typeof claims.sub !== "string" || !/^[A-Za-z0-9_-]{22,64}$/.test(claims.sub)) errors.push("sub must be 22-64 chars of A-Z a-z 0-9 _ -");
  else if (/^\d+$/.test(claims.sub)) errors.push("sub must not be all digits (looks like a raw user id)");
  if (claims.kyc !== "verified") errors.push('kyc must be "verified"');
  if (!Number.isInteger(claims.mapping_version)) errors.push("mapping_version must be an integer");
  if (!Number.isInteger(claims.iat) || !Number.isInteger(claims.exp)) errors.push("iat and exp must be integer seconds");
  else {
    if (claims.exp - claims.iat > 86400) errors.push("exp - iat is more than 24 hours");
    if (claims.exp * 1000 < now) errors.push("token is expired");
  }
  if (typeof claims.jti !== "string" || !claims.jti) errors.push("jti must be a non-empty string");
  if (!claims.attrs || typeof claims.attrs !== "object" || Array.isArray(claims.attrs)) errors.push("attrs must be an object");
  else
    for (const [k, v] of Object.entries(claims.attrs)) {
      if (!(k in ATTRS)) errors.push(`attrs.${k} is not in the attribute vocabulary`);
      else if (!ATTRS[k](v, year)) {
        errors.push(
          k === "governorate" || k === "city"
            ? `attrs.${k} must be a FOUNTIS location code in lower case, e.g. "erbil" (names, phone numbers and your own codes are refused)`
            : `attrs.${k} has an invalid value (${JSON.stringify(v)})`,
        );
      }
    }
  return { ok: errors.length === 0, errors, warnings, header, claims };
}
