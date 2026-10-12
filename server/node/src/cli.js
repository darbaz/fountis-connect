#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { checkToken } from "./index.js";

const [cmd, token, ...rest] = process.argv.slice(2);
if (cmd !== "check" || !token) {
  console.error("usage: npx @fountispanel/connect-server check <token> [--jwk public-jwk.json]");
  process.exit(2);
}

const r = checkToken(token);
if (r.claims) {
  const c = r.claims;
  console.log(`alg ${r.header.alg}, kid ${r.header.kid ?? "-"}`);
  console.log(`iss ${c.iss}  aud ${c.aud}  sub ${String(c.sub).slice(0, 8)}...  mapping v${c.mapping_version}`);
  console.log(`attrs ${JSON.stringify(c.attrs)}`);
  if (Number.isInteger(c.exp)) console.log(`expires ${new Date(c.exp * 1000).toISOString()}`);
}

const jwkAt = rest.indexOf("--jwk");
if (jwkAt !== -1 && rest[jwkAt + 1]) {
  try {
    const { jwtVerify, importJWK } = await import("jose");
    const jwk = JSON.parse(readFileSync(rest[jwkAt + 1], "utf8"));
    await jwtVerify(token, await importJWK(jwk, "ES256"), { algorithms: ["ES256"] });
    console.log("signature OK");
  } catch (e) {
    r.errors.push(`signature check failed: ${e.message}`);
    r.ok = false;
  }
}

for (const w of r.warnings ?? []) console.log(`note: ${w}`);
if (r.errors.length) {
  for (const e of r.errors) console.error(`- ${e}`);
}
console.log(r.ok ? "token looks valid" : "token has problems");
process.exit(r.ok ? 0 : 1);
