#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  print "Usage: ./scripts/bench-menu-bar.sh"
  print "Builds the Mac app's sources with scripts/bench/MenuBarObservationBench.swift (swiftc -O -wmo) and counts how often the status item"
  print "reads the menu bar's meters while a check's results arrive, with the observer before BatchedObservation and with it."
  print "BENCH_ROUNDS (default 5) rounds per spacing, BENCH_OUT (default \$TMPDIR/tokenroom-menu-bench) for the binary and raw CSV."
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${BENCH_OUT:-${TMPDIR:-/tmp}/tokenroom-menu-bench}"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx15.0"
mkdir -p "$OUT"
sources=("${(@f)$(find Tokenroom Shared/Core Shared/Relay Shared/UI Shared/APIKeys -name '*.swift' -not -name 'TokenroomApp.swift' | sort)}")

swiftc -O -wmo -parse-as-library -swift-version 6 -lsqlite3 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$TARGET" \
  -o "$OUT/menu-bar-bench" \
  "${sources[@]}" scripts/bench/MenuBarObservationBench.swift 2> "$OUT/build.log" || {
    grep -E "error" "$OUT/build.log" >&2
    exit 1
  }

commit="$(git rev-parse --short HEAD)"
git diff --quiet HEAD -- Tokenroom Shared scripts/bench scripts/bench-menu-bar.sh || commit="$commit with uncommitted changes"
print "tree: $commit"
print "build: swiftc -O -wmo -swift-version 6, $TARGET, $(swiftc --version 2>/dev/null | head -1)"
print "host: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)"
"$OUT/menu-bar-bench" | tee "$OUT/menu-bar.csv"

python3 - "$OUT/menu-bar.csv" <<'SUMMARY'
import csv, statistics, sys

lines = open(sys.argv[1]).read().strip().split("\n")
rows = list(csv.DictReader(lines[1:]))
print("\nMedian per burst of one result per provider (each followed by the presentation clock's restart)")
print(f"{'spacing':>8} {'observer':>8} {'readings':>9} {'reading ms':>11} {'applied':>8} {'first shown ms':>15} {'last shown ms':>14}")
for spacing in sorted({r["spacing_ms"] for r in rows}, key=float):
    for observer in ("legacy", "batched"):
        group = [r for r in rows if r["spacing_ms"] == spacing and r["observer"] == observer]
        def median(key):
            values = [float(r[key]) for r in group if r[key] != "never"]
            return statistics.median(values) if values else float("nan")
        print(f"{spacing:>6}ms {observer:>8} {median('readings'):9.0f} {median('reading_ms'):11.3f} {median('applied'):8.0f} "
              f"{median('first_shown_after_first_change_ms'):15.1f} {median('last_shown_after_last_change_ms'):14.1f}")
SUMMARY
