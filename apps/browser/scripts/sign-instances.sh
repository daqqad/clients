#!/usr/bin/env bash

####
# Sign the Firefox instance builds for self-distribution (AMO "unlisted" channel).
#
# Credentials are read from the first file that exists:
#   $AMO_CREDENTIALS_FILE, ~/.mozilla/.dev_hub_api_key, ~/.amo
# JSON, shell (KEY=VALUE) and "JWT issuer: ... / JWT secret: ..." layouts are all
# understood; the issuer is matched as user:<n>:<n> and the secret as a long hex
# string. Values are never echoed. Generate a key pair at addons.mozilla.org ->
# Developer Hub -> Manage API Keys.
#
# Usage: ./scripts/sign-instances.sh [instance ...]      (default: work personal)
####

set -e
set -u
set -o pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BROWSER_DIR="$(dirname "$SCRIPT_ROOT")"
ARTIFACTS_DIR="$BROWSER_DIR/web-ext-artifacts"

# Populates AMO_JWT_ISSUER / AMO_JWT_SECRET without printing them.
eval "$(
  AMO_CREDENTIALS_FILE="${AMO_CREDENTIALS_FILE:-}" python3 - <<'PY'
import json
import os
import pathlib
import re
import shlex
import sys

candidates = [
    os.environ.get("AMO_CREDENTIALS_FILE") or "",
    os.path.expanduser("~/.mozilla/.dev_hub_api_key"),
    os.path.expanduser("~/.amo"),
]

issuer = os.environ.get("AMO_JWT_ISSUER")
secret = os.environ.get("AMO_JWT_SECRET")
source = "environment"

for candidate in candidates:
    if issuer and secret:
        break
    if not candidate:
        continue
    path = pathlib.Path(candidate)
    if not path.is_file():
        continue

    text = path.read_text()
    source = candidate

    try:
        data = json.loads(text)
    except ValueError:
        data = None

    if isinstance(data, dict):
        flat = {str(k).lower(): str(v) for k, v in data.items() if isinstance(v, (str, int))}
        for key, value in flat.items():
            if issuer is None and ("issuer" in key or key in ("api_key", "key", "jwt_issuer")):
                issuer = value
            if secret is None and "secret" in key:
                secret = value

    if issuer is None:
        match = re.search(r"user:\d+:\d+", text)
        issuer = match.group(0) if match else None
    if secret is None:
        match = re.search(r"\b[0-9a-f]{32,}\b", text)
        secret = match.group(0) if match else None

if not issuer or not secret:
    print(
        "echo 'Could not find AMO credentials (looked in "
        f"{', '.join(c for c in candidates if c)})' >&2; exit 1"
    )
    sys.exit(0)

print(f"AMO_JWT_ISSUER={shlex.quote(issuer)}")
print(f"AMO_JWT_SECRET={shlex.quote(secret)}")
print(f"echo 'Using AMO credentials from {source}'")
PY
)"

export AMO_JWT_ISSUER AMO_JWT_SECRET

INSTANCES=("$@")
if [ ${#INSTANCES[@]} -eq 0 ]; then
  INSTANCES=(work personal)
fi

for instance in "${INSTANCES[@]}"; do
  SOURCE_DIR="$BROWSER_DIR/build-$instance"

  if [ ! -d "$SOURCE_DIR" ]; then
    echo "Missing $SOURCE_DIR - run 'npm run build:firefox:instances' first" >&2
    exit 1
  fi

  NAME="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$SOURCE_DIR/manifest.json")"
  echo "==> Signing $instance ($NAME)"

  npx --yes web-ext sign \
    --source-dir "$SOURCE_DIR" \
    --artifacts-dir "$ARTIFACTS_DIR" \
    --channel unlisted \
    --api-key "$AMO_JWT_ISSUER" \
    --api-secret "$AMO_JWT_SECRET"
done

echo
echo "Signed XPIs in $ARTIFACTS_DIR:"
ls -1 "$ARTIFACTS_DIR"/*.xpi 2>/dev/null || echo "(none)"
