#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-run}"
derived="${HAPI_MAC_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/HapiCatalyst}"
installed="$HOME/Applications/HAPI Catalyst.app"
config="${HAPI_MAC_CONFIGURATION:-Release}"
if [[ "$mode" == "--debug" ]]; then
  config="Debug"
fi
xcodebuild -project ios/Hapi.xcodeproj -scheme Hapi -configuration "$config" \
  -destination "platform=macOS,variant=Mac Catalyst,arch=$(uname -m)" \
  -derivedDataPath "$derived" -allowProvisioningUpdates build
built="$derived/Build/Products/${config}-maccatalyst/Hapi.app"
if [[ -e "$installed" ]]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed/Contents/Info.plist")
  [[ "$bundle_id" == com.sagewe.hapi ]] || { echo 'Installation path belongs to another app' >&2; exit 1; }
fi
pkill -x Hapi >/dev/null 2>&1 || true
rm -rf "$installed"
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$built" "$installed"
codesign --verify --deep --strict "$installed"
case "$mode" in
  --install-only) echo "Installed and verified $installed" ;;
  run) open -n "$installed" ;;
  --verify) open -n "$installed"; sleep 2; pgrep -x Hapi >/dev/null ;;
  --debug) lldb -- "$installed/Contents/MacOS/Hapi" ;;
  --logs|--telemetry) open -n "$installed"; /usr/bin/log stream --info --style compact --predicate 'process == "Hapi"' ;;
  *) echo 'usage: build_and_run.sh [--install-only|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;;
esac
