#!/usr/bin/env bash
# Deploy Hermes Mobile to a physical iPhone WITHOUT wiping the gateway book.
#
# CRITICAL: do NOT use `flutter install` — on iOS it "Uninstalling old version…"
# which wipes Application Support (connection mirror). Use devicectl upgrade install.
# Keychain access-group is the second line of defense across reinstalls.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FLUTTER_DEVICE_ID="${1:-}"
if [[ -z "$FLUTTER_DEVICE_ID" ]]; then
  FLUTTER_DEVICE_ID="$(
    flutter devices 2>/dev/null \
      | awk -F '•' '/mobile/ && /ios/ && !/simulator/ {
          gsub(/^ +| +$/, "", $2); print $2; exit
        }'
  )"
fi

if [[ -z "$FLUTTER_DEVICE_ID" ]]; then
  echo "No physical iOS device found. Unlock the phone, trust this Mac, then retry." >&2
  echo "Usage: $0 [flutter-device-id]" >&2
  exit 1
fi

echo "==> Building release for $FLUTTER_DEVICE_ID"
HERMES_GO_PRIVACY_POLICY_URL="${HERMES_PRIVACY_POLICY_URL:-https://github.com/TheTom/hermes-go/blob/mobile-gateway/PRIVACY.md}"
flutter build ios --release -d "$FLUTTER_DEVICE_ID" \
  --dart-define="HERMES_PRIVACY_POLICY_URL=$HERMES_GO_PRIVACY_POLICY_URL"

APP_PATH="$ROOT/build/ios/iphoneos/Runner.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing $APP_PATH" >&2
  exit 1
fi

JSON_OUT="$(mktemp -t hermes-devices)"
xcrun devicectl list devices --json-output "$JSON_OUT" >/dev/null

CORE_DEVICE_ID="$(
  FLUTTER_DEVICE_ID="$FLUTTER_DEVICE_ID" python3 - "$JSON_OUT" <<'PY'
import json, os, sys
from pathlib import Path

want = os.environ.get("FLUTTER_DEVICE_ID", "").strip()
data = json.loads(Path(sys.argv[1]).read_text())
devices = data.get("result", {}).get("devices") or data.get("devices") or []

def udid_of(d):
    hw = d.get("hardwareProperties") or {}
    return (hw.get("udid") or hw.get("deviceIdentifier") or "").strip()

def ident_of(d):
    return (d.get("identifier") or "").strip()

def reality_of(d):
    props = d.get("deviceProperties") or {}
    hw = d.get("hardwareProperties") or {}
    return (props.get("reality") or hw.get("reality") or "").strip()

# Exact UDID match first
for d in devices:
    if udid_of(d) == want and ident_of(d):
        print(ident_of(d))
        raise SystemExit(0)

# Any physical device
for d in devices:
    if reality_of(d) == "physical" and ident_of(d):
        print(ident_of(d))
        raise SystemExit(0)

raise SystemExit(1)
PY
)" || true
rm -f "$JSON_OUT"

if [[ -z "${CORE_DEVICE_ID:-}" ]]; then
  echo "Could not resolve CoreDevice id; refusing flutter install (it uninstalls)." >&2
  echo "Install manually:" >&2
  echo "  xcrun devicectl device install app --device <CORE_ID> \"$APP_PATH\"" >&2
  exit 1
fi

echo "==> Upgrade-install via devicectl (no uninstall) → $CORE_DEVICE_ID"
xcrun devicectl device install app --device "$CORE_DEVICE_ID" "$APP_PATH"

echo "==> Done. Gateway connection should still be on device (Keychain + mirror)."
echo "    Unlock phone and open Hermes Mobile if needed."
