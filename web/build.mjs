// dist/connect.js   : browser bundle, global `FountisConnect` (+ CommonJS/AMD when present), minified
// dist/connect.esm.js / connect.cjs / connect.d.ts : for npm (`@fountispanel/connect`)
import { build } from "esbuild";
import { gzipSync } from "node:zlib";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const common = { entryPoints: ["src/index.ts"], bundle: true, target: "es2019", legalComments: "none" };

await build({
  ...common,
  format: "iife",
  globalName: "FountisConnect",
  minify: true,
  outfile: "dist/connect.js",
  footer: {
    js: "if(typeof module==='object'&&module.exports)module.exports=FountisConnect;else if(typeof define==='function'&&define.amd)define(function(){return FountisConnect});",
  },
});
await build({ ...common, format: "esm", outfile: "dist/connect.esm.js", minify: false });
await build({ ...common, format: "cjs", outfile: "dist/connect.cjs", minify: false });
execFileSync("npx", ["tsc", "-p", ".", "--declarationMap", "false"], { stdio: "inherit" });
try {
  // tsc emits dist/index.d.ts; the package points at connect.d.ts
  execFileSync("mv", ["dist/index.d.ts", "dist/connect.d.ts"]);
} catch {}
const js = readFileSync("dist/connect.js");
console.log(`connect.js ${js.length} B, gzip ${gzipSync(js).length} B`);
