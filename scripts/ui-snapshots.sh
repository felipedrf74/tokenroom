#!/bin/zsh
# Render every Tokenroom screen from sample data to PNGs, for design review. Nothing here reads a
# login, a key, or iCloud, and nothing is installed over the real app.
#
#   ./scripts/ui-snapshots.sh <folder> [mac] [iphone] [watch]
#
# Screens go to <folder>/{mac,iphone,watch}. With no platform named, all three run. The iPhone and
# Watch screens are XCUITest screenshots on a Simulator, so their Liquid Glass is the real thing.
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
python3 "$ROOT/scripts/ui-snapshot-fixture.py" "$FIXTURE" >/dev/null

for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    mac)
      mkdir -p "$OUT/mac"
      xcodebuild build -project "$ROOT/Tokenroom.xcodeproj" -scheme Tokenroom -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO -quiet
      "$DERIVED/Build/Products/Debug/Tokenroom.app/Contents/MacOS/Tokenroom" \
        -TokenroomSnapshots "$OUT/mac" -TokenroomSnapshotNews "$FIXTURE/news.json" -AppleLocale en_US
      ;;
    iphone)
      rm -rf "$OUT/iphone.xcresult"
      TEST_RUNNER_TOKENROOM_SNAPSHOT_DIR="$OUT/iphone" TEST_RUNNER_TOKENROOM_SNAPSHOT_FIXTURE="$FIXTURE/news.json" \
        xcodebuild test -project "$ROOT/Tokenroom.xcodeproj" -scheme TokenroomUISnapshots \
        -destination "platform=iOS Simulator,name=$IPHONE" -derivedDataPath "$DERIVED" \
        -resultBundlePath "$OUT/iphone.xcresult" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO TOKENROOM_CK_CONTAINER= -quiet
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
