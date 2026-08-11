#!/usr/bin/env bash

####
# Build, sign and publish the Firefox instance builds so installed copies update
# themselves.
#
# Self-distributed add-ons get nothing from AMO: Firefox only updates them by
# polling the update manifest named in browser_specific_settings.gecko.update_url
# (roughly every 24h). This script produces that manifest and uploads it, along
# with the signed xpis, to the R2 prefix recorded in r2-prefix.local.
#
# Bump "build" in instances.json before running, otherwise AMO rejects the
# version as already signed.
#
# Credentials: ~/.mozilla/.dev_hub_api_key for AMO, the [Personal] section of
# ~/.cloudflare/cloudflare.cfg for R2.
#
# Usage: ./scripts/publish-instances.sh [--skip-build] [--skip-sign]
####

set -e
set -u
set -o pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BROWSER_DIR="$(dirname "$SCRIPT_ROOT")"
ARTIFACTS_DIR="$BROWSER_DIR/web-ext-artifacts"
BUCKET=daqfx-pub

SKIP_BUILD=0
SKIP_SIGN=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --skip-sign) SKIP_SIGN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

PREFIX="$(cat "$BROWSER_DIR/r2-prefix.local")"
[ -n "$PREFIX" ] || { echo "r2-prefix.local is empty" >&2; exit 1; }

cd "$BROWSER_DIR"

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> building"
  npm run build:firefox:instances
fi

if [ "$SKIP_SIGN" -eq 0 ]; then
  echo "==> signing"
  "$SCRIPT_ROOT/sign-instances.sh"
fi

# Cloudflare credentials for the personal account, never echoed.
eval "$(python3 - <<'PY'
import configparser, pathlib, shlex
cp = configparser.ConfigParser()
cp.read(pathlib.Path.home() / ".cloudflare/cloudflare.cfg")
s = cp["Personal"]
print(f"export CLOUDFLARE_API_KEY={shlex.quote(s['global_api_key'])}")
print(f"export CLOUDFLARE_EMAIL={shlex.quote(s['email'])}")
print(f"export CLOUDFLARE_ACCOUNT_ID={shlex.quote(s['account_id'])}")
PY
)"

echo "==> building update manifest"
python3 - "$BROWSER_DIR" "$PREFIX" <<'PY'
import glob, hashlib, json, pathlib, sys, zipfile

browser_dir, prefix = pathlib.Path(sys.argv[1]), sys.argv[2]
base = f"https://pub-74fd52fbbb144eb3876bf8871b531322.r2.dev/{prefix}"
instances = json.loads((browser_dir / "instances.json").read_text())

addons, uploads = {}, []
for name, cfg in instances.items():
    # newest signed xpi for this instance, identified by the id inside it
    best = None
    for path in glob.glob(str(browser_dir / "web-ext-artifacts" / "*.xpi")):
        manifest = json.loads(zipfile.ZipFile(path).read("manifest.json"))
        if manifest["browser_specific_settings"]["gecko"]["id"] != cfg["geckoId"]:
            continue
        version = tuple(int(p) for p in manifest["version"].split("."))
        if best is None or version > best[0]:
            best = (version, path, manifest["version"])
    if best is None:
        raise SystemExit(f"no signed xpi found for {name} ({cfg['geckoId']})")

    _, path, version = best
    filename = f"bitwarden-{name}-{version}.xpi"
    digest = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    addons[cfg["geckoId"]] = {
        "updates": [{
            "version": version,
            "update_link": f"{base}/{filename}",
            "update_hash": f"sha256:{digest}",
        }]
    }
    uploads.append((path, filename))
    print(f"  {name}: {version}  sha256 {digest[:12]}…")

(browser_dir / "updates.json").write_text(json.dumps({"addons": addons}, indent=2) + "\n")
(browser_dir / "uploads.local").write_text("\n".join(f"{p}\t{n}" for p, n in uploads) + "\n")
PY

echo "==> uploading to r2://$BUCKET/$PREFIX/"
while IFS=$'\t' read -r path filename; do
  [ -n "$path" ] || continue
  echo "  $filename"
  wrangler r2 object put "$BUCKET/$PREFIX/$filename" \
    --file "$path" --content-type application/x-xpinstall --remote >/dev/null
done < uploads.local

# Uploaded last so the manifest never advertises an xpi that is not yet there.
echo "  updates.json"
wrangler r2 object put "$BUCKET/$PREFIX/updates.json" \
  --file updates.json --content-type application/json --remote >/dev/null

rm -f uploads.local

echo "==> verifying public URLs"
BASE="https://pub-74fd52fbbb144eb3876bf8871b531322.r2.dev/$PREFIX"
for url in "$BASE/updates.json" $(python3 -c "
import json,pathlib
d=json.loads(pathlib.Path('updates.json').read_text())
print(' '.join(u['update_link'] for a in d['addons'].values() for u in a['updates']))
"); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url")
  printf "  %-6s %s\n" "$code" "${url##*/}"
done

echo
echo "Done. Firefox checks for updates about every 24h."
echo "To test immediately: about:addons -> gear -> Check for Updates"
