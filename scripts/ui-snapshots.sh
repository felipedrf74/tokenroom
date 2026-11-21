#!/bin/zsh
# Render every Tokenroom screen from sample data to PNGs, for design review. Nothing here reads a
# login, a key, or iCloud, and nothing is installed over the real app.
#
#   ./scripts/ui-snapshots.sh <folder> [mac] [iphone] [watch]
#
# Screens go to <folder>/{mac,iphone,watch}. With no platform named, all three run. The iPhone and
# Watch screens are XCUITest screenshots on a Simulator, so their Liquid Glass is the real thing.
# TOKENROOM_SNAPSHOT_ONLY=testNews runs one iPhone capture test; DERIVED_DATA_PATH keeps two
# checkouts apart; TOKENROOM_SNAPSHOT_IPHONE and TOKENROOM_SNAPSHOT_WATCH pick the Simulators.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: ui-snapshots.sh <folder> [mac] [iphone] [watch]}"
shift
PLATFORMS=("$@")
(( ${#PLATFORMS} )) || PLATFORMS=(mac iphone watch)
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/Tokenroom}"
IPHONE="${TOKENROOM_SNAPSHOT_IPHONE:-iPhone 18 Pro}"
WATCH="${TOKENROOM_SNAPSHOT_WATCH:-Apple Watch Series 12 (46mm)}"
FIXTURE="$OUT/fixture"
fixture() { python3 "$ROOT/scripts/ui-snapshot-fixture.py" "$FIXTURE" >/dev/null; }
fixture

for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    mac)
      mkdir -p "$OUT/mac"
      xcodebuild build -project "$ROOT/Tokenroom.xcodeproj" -scheme Tokenroom -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO -quiet
      fixture
      "$DERIVED/Build/Products/Debug/Tokenroom.app/Contents/MacOS/Tokenroom" \
        -TokenroomSnapshots "$OUT/mac" -TokenroomSnapshotNews "$FIXTURE/news.json" -AppleLocale en_US
      ;;
    iphone)
      rm -rf "$OUT/iphone.xcresult" "$OUT/iphone-light.xcresult" "$OUT/iphone-dark.xcresult"
      only=()
      [[ -n "${TOKENROOM_SNAPSHOT_ONLY:-}" ]] && only=("-only-testing:TokenroomUISnapshots/UISnapshotTests/$TOKENROOM_SNAPSHOT_ONLY")
      xcodebuild build-for-testing -project "$ROOT/Tokenroom.xcodeproj" -scheme TokenroomUISnapshots \
        -destination "platform=iOS Simulator,name=$IPHONE" -derivedDataPath "$DERIVED" \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO TOKENROOM_CK_CONTAINER= -quiet
      # The iOS 27 Simulator applies a new appearance only after it boots again, so each look gets
      # its own boot and its own run, and the test keeps only the captures of the look it was given.
      udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group if d.get("name") == name and d.get("isAvailable", True)]
idle = [d for d in devices if d.get("state") == "Shutdown"]
booted = [d for d in devices if d.get("state") == "Booted"]
chosen = (idle or booted)[:1]
print(chosen[0]["udid"], chosen[0].get("state", "")) if chosen else print("")
' "$IPHONE")"
      read -r udid udid_state <<<"$udid"
      if [[ -z "$udid" ]]; then
        echo "Couldn't find a shut-down or booted Simulator named $IPHONE" >&2
        exit 2
      fi
      # Put the Simulator back as it was found: its appearance, and booted only if it was.
      original_look=""
      restore_iphone() {
        if [[ "$udid_state" == "Booted" && "$original_look" != light && "$original_look" != dark ]]; then return; fi
        if [[ "$original_look" == light || "$original_look" == dark ]]; then
          xcrun simctl boot "$udid" 2>/dev/null || true
          xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
          xcrun simctl ui "$udid" appearance "$original_look" ||
            echo "Couldn't restore the $original_look appearance of Simulator $udid" >&2
        fi
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        if [[ "$udid_state" == "Booted" ]]; then
          xcrun simctl boot "$udid" || echo "Couldn't boot Simulator $udid again" >&2
        fi
      }
      trap restore_iphone EXIT
      xcrun simctl boot "$udid" 2>/dev/null || true
      xcrun simctl bootstatus "$udid" -b >/dev/null
      original_look="$(xcrun simctl ui "$udid" appearance 2>/dev/null || true)"
      if [[ "$original_look" != light && "$original_look" != dark ]]; then
        echo "Couldn't read the appearance of Simulator $udid" >&2
        exit 2
      fi
      for look in light dark; do
        xcrun simctl ui "$udid" appearance "$look"
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        xcrun simctl boot "$udid"
        xcrun simctl bootstatus "$udid" -b >/dev/null
        fixture
        TEST_RUNNER_TOKENROOM_SNAPSHOT_DIR="$OUT/iphone" TEST_RUNNER_TOKENROOM_SNAPSHOT_FIXTURE="$FIXTURE/news.json" \
          TEST_RUNNER_TOKENROOM_SNAPSHOT_LOOK="$look" \
          xcodebuild test-without-building -project "$ROOT/Tokenroom.xcodeproj" -scheme TokenroomUISnapshots "${only[@]}" \
          -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DERIVED" \
          -resultBundlePath "$OUT/iphone-$look.xcresult" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO TOKENROOM_CK_CONTAINER= -quiet
      done
      restore_iphone
      trap - EXIT
      ;;
    watch)
      rm -rf "$OUT/watch.xcresult"
      TEST_RUNNER_TOKENROOM_SNAPSHOT_DIR="$OUT/watch" \
        xcodebuild test -project "$ROOT/Tokenroom.xcodeproj" -scheme TokenroomWatchUISnapshots \
        -destination "platform=watchOS Simulator,name=$WATCH" -derivedDataPath "$DERIVED" \
        -resultBundlePath "$OUT/watch.xcresult" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO TOKENROOM_CK_CONTAINER= -quiet
      ;;
    *)
      echo "Unknown platform: $platform" >&2
      exit 2
      ;;
  esac
done
echo "Screens in $OUT"
