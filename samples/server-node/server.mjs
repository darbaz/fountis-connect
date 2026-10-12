// Minimal token endpoint for a partner backend. No framework: node server.mjs
//   FOUNTIS_SIGNING_KEY  PEM (PKCS#8, P-256)     FOUNTIS_USER_SECRET  long random string
//   FOUNTIS_APP_ID / FOUNTIS_PARTNER_ID / FOUNTIS_KID
import { createServer } from "node:http";
import { createUserToken, createUnsignedToken, verifyWebhook } from "@fountispanel/connect-server";

const env = process.env;
const mapping = {
  version: 1,
  attributes: {
    gender: { field: "sex", values: { M: "male", F: "female" } },
    birth_year: { field: "dob", transform: "year" },
    city: { field: "city", values: { Erbil: "erbil", Sulaymaniyah: "sulaymaniyah" } },
  },
};

// Replace with your real session lookup. Never trust a user id sent by the browser.
function currentUser(req) {
  return req.headers.cookie?.includes("session=") ? { id: 4711, sex: "F", dob: "1991-05-02", city: "Erbil" } : null;
}

const readBody = async (req) => Buffer.concat(await req.toArray());

createServer(async (req, res) => {
  const json = (code, obj) => res.writeHead(code, { "Content-Type": "application/json" }).end(JSON.stringify(obj));

  if (req.method === "GET" && req.url === "/fountis/token") {
    const user = currentUser(req);
    if (!user) return json(401, { error: "not_signed_in" });
    try {
      const args = { appId: env.FOUNTIS_APP_ID, partnerId: env.FOUNTIS_PARTNER_ID, userSecret: env.FOUNTIS_USER_SECRET, mapping, user };
      const token = env.FOUNTIS_SIGNING_KEY
        ? await createUserToken({ ...args, signingKey: env.FOUNTIS_SIGNING_KEY, kid: env.FOUNTIS_KID })
        : createUnsignedToken(args); // sandbox keys only
      return json(200, { token });
    } catch (e) {
      return json(e.code === "not_adult" ? 403 : 500, { error: e.code ?? "error" });
    }
  }

  if (req.method === "POST" && req.url === "/fountis/webhook") {
    const raw = await readBody(req);
    if (!verifyWebhook(raw, req.headers["fountis-signature"], env.FOUNTIS_WEBHOOK_SECRET)) return json(400, { error: "bad_signature" });
    console.log("FOUNTIS event:", JSON.parse(raw.toString()));
    return json(200, { ok: true });
  }

  json(404, { error: "not_found" });
}).listen(Number(env.PORT ?? 3000), () => console.log("token endpoint on :" + (env.PORT ?? 3000)));
