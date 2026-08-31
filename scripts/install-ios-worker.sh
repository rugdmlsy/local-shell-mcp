#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/ios/LSMMobileWorker/LSMMobileWorker.xcodeproj"
SPEC="$ROOT/ios/LSMMobileWorker/project.yml"
SCHEME="LSMMobileWorker"
CONFIGURATION="Debug"
BUNDLE_ID="com.xycdev.lsmmobileworker"
DERIVED_DATA="${TMPDIR:-/tmp}/LSMWorkerDevice"
TEAM_ID="${LSM_IOS_DEVELOPMENT_TEAM:-}"
DEVICE_SELECTOR=""
NO_LAUNCH=0
BUILD_ONLY=0

usage() {
  cat <<USAGE
Usage: scripts/install-ios-worker.sh [options]

Build, sign, install, launch, and verify the normal LSM Worker Debug app on a
physical iPhone. The script intentionally does not use the Share/Push targets.

Options:
  --device <id|name>       Target device. Default: the only connected physical iPhone.
  --team <team-id>         Apple Development Team ID. Default: LSM_IOS_DEVELOPMENT_TEAM,
                           then an existing matching provisioning profile.
  --derived-data <path>    DerivedData directory. Default: $DERIVED_DATA
  --build-only             Build/sign only; do not install or launch.
  --no-launch              Install and verify but do not launch.
  -h, --help               Show this help.

Environment:
  LSM_IOS_DEVELOPMENT_TEAM Apple Development Team ID override.
USAGE
}

while (($#)); do
  case "$1" in
    --device)
      DEVICE_SELECTOR="${2:?--device requires a value}"
      shift 2
      ;;
    --team)
      TEAM_ID="${2:?--team requires a value}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:?--derived-data requires a value}"
      shift 2
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --no-launch)
      NO_LAUNCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for cmd in xcrun xcodebuild xcodegen python3 security codesign plutil; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "error: iOS deployment must run on macOS" >&2; exit 1; }
[[ -f "$SPEC" ]] || { echo "error: missing project spec: $SPEC" >&2; exit 1; }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lsm-ios-install.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

DEVICE_JSON="$TMP_ROOT/devices.json"
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null

DEVICE_INFO="$(python3 - "$DEVICE_JSON" "$DEVICE_SELECTOR" <<'PY'
import json, sys
path, selector = sys.argv[1:]
data = json.load(open(path))
devices = data.get("result", {}).get("devices", [])
physical = []
for d in devices:
    hp = d.get("hardwareProperties", {})
    cp = d.get("connectionProperties", {})
    dp = d.get("deviceProperties", {})
    if hp.get("platform") != "iOS" or hp.get("reality") != "physical":
        continue
    if cp.get("pairingState") != "paired" or cp.get("tunnelState") != "connected":
        continue
    physical.append(d)

def keys(d):
    hp = d.get("hardwareProperties", {})
    dp = d.get("deviceProperties", {})
    return {
        str(d.get("identifier", "")), str(hp.get("udid", "")),
        str(hp.get("serialNumber", "")), str(dp.get("name", "")),
    }

if selector:
    matches = [d for d in physical if selector in keys(d)]
else:
    matches = physical

if len(matches) != 1:
    print("ERROR", file=sys.stderr)
    print(f"Expected exactly one connected physical iPhone, found {len(matches)} matching device(s).", file=sys.stderr)
    for d in physical:
        hp, dp = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
        print(f"  {dp.get('name','?')}  {hp.get('marketingName','?')}  UDID={hp.get('udid','?')}", file=sys.stderr)
    if physical and not selector:
        print("Use --device <UDID-or-name> to choose one.", file=sys.stderr)
    sys.exit(3)

d = matches[0]
hp, dp = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
print("\t".join([
    str(hp.get("udid", "")),
    str(dp.get("name", "")),
    str(hp.get("marketingName", "")),
    str(dp.get("osVersionNumber", "")),
]))
PY
)"

IFS=$'\t' read -r DEVICE_UDID DEVICE_NAME DEVICE_MODEL DEVICE_OS <<<"$DEVICE_INFO"
[[ -n "$DEVICE_UDID" ]] || { echo "error: selected device has no UDID" >&2; exit 1; }

echo "Device: $DEVICE_NAME ($DEVICE_MODEL, iOS $DEVICE_OS)"
echo "UDID:   $DEVICE_UDID"

resolve_team_from_profiles() {
  local roots=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    "$HOME/Library/MobileDevice/Provisioning Profiles"
  )
  local f plist result
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' f; do
      plist="$TMP_ROOT/profile.plist"
      security cms -D -i "$f" >"$plist" 2>/dev/null || continue
      result="$(python3 - "$plist" "$BUNDLE_ID" "$DEVICE_UDID" <<'PY'
import datetime, plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
bundle, udid = sys.argv[2:]
ent = p.get("Entitlements", {})
app_id = str(ent.get("application-identifier", ""))
if not app_id.endswith("." + bundle):
    raise SystemExit(1)
if udid not in p.get("ProvisionedDevices", []):
    raise SystemExit(1)
exp = p.get("ExpirationDate")
now = datetime.datetime.now(datetime.timezone.utc)
if exp is not None:
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=datetime.timezone.utc)
    if exp <= now:
        raise SystemExit(1)
teams = p.get("TeamIdentifier", [])
if teams:
    print(teams[0])
else:
    raise SystemExit(1)
PY
)" || continue
      if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
      fi
    done < <(find "$root" -type f -name '*.mobileprovision' -print0 2>/dev/null)
  done
  return 1
}

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(resolve_team_from_profiles || true)"
fi

if [[ -z "$TEAM_ID" ]]; then
  cat >&2 <<EOF2
error: could not determine Apple Development Team ID.
Pass --team <TEAM_ID> or set LSM_IOS_DEVELOPMENT_TEAM. Once Xcode has created
a matching development profile, future runs can resolve it automatically.
EOF2
  exit 1
fi

echo "Team:   $TEAM_ID"

# Keep the generated project synchronized with project.yml before building.
xcodegen generate --spec "$SPEC" --project "$(dirname "$PROJECT")" >/dev/null

rm -rf "$DERIVED_DATA"
mkdir -p "$(dirname "$DERIVED_DATA")"

echo "Building signed ${SCHEME}/${CONFIGURATION}..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "id=$DEVICE_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  "DEVELOPMENT_TEAM=$TEAM_ID" \
  -allowProvisioningUpdates \
  build

APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/LSM Worker.app"
[[ -d "$APP" ]] || { echo "error: signed app not found at $APP" >&2; exit 1; }
[[ -f "$APP/embedded.mobileprovision" ]] || { echo "error: app has no embedded provisioning profile" >&2; exit 1; }

codesign --verify --deep --strict "$APP"
BUILT_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
[[ "$BUILT_BUNDLE" == "$BUNDLE_ID" ]] || { echo "error: unexpected bundle id: $BUILT_BUNDLE" >&2; exit 1; }

PROFILE_PLIST="$TMP_ROOT/embedded.plist"
security cms -D -i "$APP/embedded.mobileprovision" >"$PROFILE_PLIST"
read -r SIGNED_TEAM PROFILE_APP_ID PROFILE_HAS_DEVICE < <(python3 - "$PROFILE_PLIST" "$DEVICE_UDID" <<'PY'
import plistlib, sys
p=plistlib.load(open(sys.argv[1], 'rb'))
teams=p.get('TeamIdentifier', [])
app_id=p.get('Entitlements', {}).get('application-identifier', '')
has='yes' if sys.argv[2] in p.get('ProvisionedDevices', []) else 'no'
print((teams[0] if teams else ''), app_id, has)
PY
)
[[ "$SIGNED_TEAM" == "$TEAM_ID" ]] || { echo "error: signed team $SIGNED_TEAM does not match requested team $TEAM_ID" >&2; exit 1; }
[[ "$PROFILE_APP_ID" == "$TEAM_ID.$BUNDLE_ID" ]] || { echo "error: provisioning application identifier mismatch: $PROFILE_APP_ID" >&2; exit 1; }
[[ "$PROFILE_HAS_DEVICE" == "yes" ]] || { echo "error: provisioning profile does not contain target device" >&2; exit 1; }

echo "Built:   $BUNDLE_ID $BUILT_VERSION"
echo "App:     $APP"

if (( BUILD_ONLY )); then
  echo "Build-only requested; stopping before install."
  exit 0
fi

echo "Installing..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"

if (( ! NO_LAUNCH )); then
  echo "Launching..."
  xcrun devicectl device process launch --terminate-existing --device "$DEVICE_UDID" "$BUNDLE_ID"
fi

APPS_JSON="$TMP_ROOT/apps.json"
xcrun devicectl device info apps --device "$DEVICE_UDID" --json-output "$APPS_JSON" >/dev/null
INSTALLED_VERSION="$(python3 - "$APPS_JSON" "$BUNDLE_ID" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
bundle=sys.argv[2]
found=[]
def walk(v):
    if isinstance(v, dict):
        if v.get('bundleIdentifier') == bundle:
            found.append(v)
        for x in v.values(): walk(x)
    elif isinstance(v, list):
        for x in v: walk(x)
walk(x)
if not found:
    raise SystemExit(4)
print(found[0].get('version', ''))
PY
)"

[[ "$INSTALLED_VERSION" == "$BUILT_VERSION" ]] || {
  echo "error: installed version $INSTALLED_VERSION does not match built version $BUILT_VERSION" >&2
  exit 1
}

echo "Verified: $BUNDLE_ID $INSTALLED_VERSION installed on $DEVICE_NAME"
