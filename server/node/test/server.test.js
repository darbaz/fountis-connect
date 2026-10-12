import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPair, exportPKCS8, jwtVerify } from "jose";
import { createUserToken, createUnsignedToken, checkToken, verifyWebhook, signWebhook, subjectFor, applyMapping } from "../src/index.js";

const mapping = {
  version: 3,
  attributes: {
    gender: { field: "sex", values: { M: "male", F: "female" } },
    birth_year: { field: "dob", transform: "year" },
    city: { field: "profile.city", values: { Erbil: "erbil", Zakho: "Zakho" } },
  },
};
const user = { id: 4711, sex: "F", dob: "1991-05-02", profile: { city: "Erbil" } };

test("mapping maps values, years and nested fields; skips what it cannot map", () => {
  assert.deepEqual(applyMapping(mapping, user), { gender: "female", birth_year: 1991, city: "erbil" });
  assert.deepEqual(applyMapping(mapping, { ...user, sex: "X", dob: null }), { city: "erbil" });
});

test("governorate and city must be FOUNTIS codes: anything else is left out, the rest of the token survives", () => {
  const m = {
    version: 1,
    attributes: {
      gender: { field: "sex", values: { M: "male", F: "female" } },
      governorate: { field: "province" },
      city: { field: "profile.city", values: { Erbil: "erbil", Zakho: "Zakho", Phone: "07501234567" } },
    },
  };
  // a value that is not in `values` is dropped (never passed through raw)
  assert.deepEqual(applyMapping(m, { sex: "F", province: "dhi_qar", profile: { city: "Duhok" } }), { gender: "female", governorate: "dhi_qar" });
  // a mapped value that is not code-shaped (wrong case, a name, a phone number) is dropped too
  assert.deepEqual(applyMapping(m, { sex: "F", profile: { city: "Zakho" } }), { gender: "female" });
  assert.deepEqual(applyMapping(m, { sex: "F", profile: { city: "Phone" } }), { gender: "female" });
  // a rule without `values` passes only code-shaped values
  for (const bad of ["Erbil", "Ali", "07501234567", "ali@example.com", "ERB-ERBIL", 7501234567]) {
    assert.deepEqual(applyMapping(m, { province: bad }), {}, String(bad));
  }
  assert.deepEqual(applyMapping(m, { province: "salah_al_din" }), { governorate: "salah_al_din" });
});

test("checkToken flags a governorate or city that is not a FOUNTIS code", () => {
  const t = createUnsignedToken({ appId: "app_x1", partnerId: "ptn_y2", userSecret: "s", mapping, user });
  const [h, p] = t.split(".");
  const claims = JSON.parse(Buffer.from(p, "base64url").toString());
  claims.attrs = { city: "ERB-ERBIL", governorate: "07501234567" };
  const errs = checkToken(`${h}.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.`).errors.join("|");
  assert.match(errs, /attrs\.city must be a FOUNTIS location code/);
  assert.match(errs, /attrs\.governorate must be a FOUNTIS location code/);
  claims.attrs = { city: "erbil", governorate: "erbil" };
  assert.deepEqual(checkToken(`${h}.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.`).errors, []);
});

test("sub is a stable keyed hash, not the id", () => {
  const a = subjectFor("secret", 4711);
  assert.equal(a, subjectFor("secret", "4711"));
  assert.notEqual(a, subjectFor("other", 4711));
  assert.match(a, /^[A-Za-z0-9_-]{22,64}$/);
});

test("createUserToken signs ES256 and the result passes check + verifies", async () => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const pem = await exportPKCS8(privateKey);
  const token = await createUserToken({
    appId: "app_x1", partnerId: "ptn_y2", signingKey: pem, kid: "k1", userSecret: "s3cret", mapping, user, lang: "ku",
  });
  const { payload, protectedHeader } = await jwtVerify(token, publicKey, { audience: "fountis-connect:app_x1", issuer: "ptn_y2" });
  assert.equal(protectedHeader.kid, "k1");
  assert.equal(payload.kyc, "verified");
  assert.equal(payload.mapping_version, 3);
  assert.deepEqual(payload.attrs, { gender: "female", birth_year: 1991, city: "erbil", lang: "ku" });
  assert.ok(payload.exp - payload.iat <= 86400);
  const r = checkToken(token);
  assert.deepEqual(r.errors, []);
  assert.ok(r.ok);
});

test("under-18 users are refused", async () => {
  const young = { ...user, dob: `${new Date().getUTCFullYear() - 10}-01-01` };
  assert.throws(() => createUnsignedToken({ appId: "app_x1", partnerId: "ptn_y2", userSecret: "s", mapping, user: young }), { code: "not_adult" });
});

test("check flags extra claims and a raw numeric sub; unsigned is only sandbox", () => {
  const t = createUnsignedToken({ appId: "app_x1", partnerId: "ptn_y2", userSecret: "s", mapping, user });
  const u = checkToken(t);
  assert.ok(u.ok && u.warnings.some((e) => e.includes("sandbox")));
  const [h, p] = t.split(".");
  const claims = JSON.parse(Buffer.from(p, "base64url").toString());
  claims.email = "a@b.c";
  claims.sub = "1234567890123456789012";
  const bad = `${h}.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.`;
  const errs = checkToken(bad).errors.join("|");
  assert.match(errs, /unexpected claim "email"/);
  assert.match(errs, /all digits/);
});

test("webhook signature: good, tampered, stale, malformed", () => {
  const body = JSON.stringify({ event: "completion", sub: "abc", units: 50 });
  const now = Date.now();
  const t = Math.floor(now / 1000);
  const good = signWebhook(body, "whsec", t);
  assert.equal(verifyWebhook(body, good, "whsec", { now }), true);
  assert.equal(verifyWebhook(Buffer.from(body), good, "whsec", { now }), true);
  assert.equal(verifyWebhook(body + " ", good, "whsec", { now }), false);
  assert.equal(verifyWebhook(body, good, "wrong", { now }), false);
  assert.equal(verifyWebhook(body, good, "whsec", { now: now + 6 * 60_000 }), false);
  assert.equal(verifyWebhook(body, "t=abc,v1=zz", "whsec", { now }), false);
  assert.equal(verifyWebhook(body, "", "whsec", { now }), false);
  // key rotation: two v1 entries, one valid
  assert.equal(verifyWebhook(body, `${good},v1=${"0".repeat(64)}`, "whsec", { now }), true);
});
