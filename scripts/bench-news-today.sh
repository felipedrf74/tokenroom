#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  print "Usage: ./scripts/bench-news-today.sh"
  print "Builds Shared/ with scripts/bench/NewsTodayBench.swift as swiftc -O -wmo (as a Release build does) and times News Today's story sections."
  print "BENCH_PAIRS (default 300), BENCH_WARMUP (default 30), BENCH_RAW=<csv path> for every sample."
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${TMPDIR:-/tmp}/tokenroom-bench"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx15.0"
mkdir -p "$OUT"
sources=("${(@f)$(find Shared -name '*.swift' -not -path 'Shared/Widgets/*' | sort)}")

swiftc -O -wmo -parse-as-library -swift-version 6 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$TARGET" \
  -o "$OUT/news-today-bench" \
  "${sources[@]}" scripts/bench/NewsTodayBench.swift 2> "$OUT/news-today-bench.build.log" || {
    grep -E "error" "$OUT/news-today-bench.build.log" >&2
    exit 1
  }

commit="$(git rev-parse --short HEAD)"
git diff --quiet HEAD -- Shared scripts/bench scripts/bench-news-today.sh || commit="$commit with uncommitted changes"

BENCH_COMMIT="$commit" \
BENCH_BUILD="swiftc -O -wmo -swift-version 6, $TARGET, $(swiftc --version 2>/dev/null | head -1)" \
BENCH_HOST="$(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores" \
  "$OUT/news-today-bench"
