// Test runner: bundles test/*.test.mjs (and the src/ they import) with esbuild, then runs the result with node:test.
// No test framework beyond Node itself; jsdom (devDependency) supplies the DOM.   Run it with: npm test
import { build } from "esbuild";
import { readdirSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(here, "../node_modules/.cache/connect-test");
rmSync(out, { recursive: true, force: true });

const entries = readdirSync(here)
  .filter((f) => f.endsWith(".test.mjs"))
  .map((f) => join(here, f));
if (entries.length === 0) {
  console.error("no test files found in test/");
  process.exit(1);
}

await build({
  entryPoints: entries,
  outdir: out,
  outExtension: { ".js": ".mjs" },
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  packages: "external", // jsdom and node: built-ins stay external; src/ and test helpers are bundled
  ignoreAnnotations: true, // package.json says "sideEffects": false (true for the library), but `import "./dom.mjs"` is the point of that file
  logLevel: "warning",
});

const files = readdirSync(out)
  .filter((f) => f.endsWith(".test.mjs"))
  .map((f) => join(out, f));
// --test-timeout: a show() that never resolves (the bug these tests guard against) must fail a test, not hang CI. The whole suite runs in well under a second.
const r = spawnSync(process.execPath, ["--test", "--test-reporter=spec", "--test-timeout=5000", ...files], { stdio: "inherit" });
process.exit(r.status ?? 1);
