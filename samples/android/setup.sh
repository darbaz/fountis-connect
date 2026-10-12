#!/bin/sh
# Writes local.properties (gitignored) with the sandbox key from ../.sandbox-keys.local.json.
set -e
cd "$(dirname "$0")"
python3 - <<'PY'
import json, os
keys = "../.sandbox-keys.local.json"
key = "pk_test_PASTE_YOUR_SANDBOX_KEY"
if os.path.exists(keys):
    key = json.load(open(keys))["apps"]["app_demo_android"]["test_key"]
else:
    print("note: ../.sandbox-keys.local.json not found; wrote a placeholder key")
# keep any sdk.dir line Android Studio already wrote
keep = [l for l in open("local.properties").read().splitlines() if not l.startswith("fountis.")] if os.path.exists("local.properties") else []
open("local.properties", "w").write("\n".join(keep + ["fountis.sandboxKey=" + key]) + "\n")
print("wrote local.properties")
PY
