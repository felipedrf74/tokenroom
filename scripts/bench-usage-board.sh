#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  print "Usage: ./scripts/bench-usage-board.sh"
  print "Builds Shared/ with scripts/bench/UsageBoardBench.swift as swiftc -O -wmo (as a Release build does) and measures what one evaluation of the iPhone's Usage tab works out, before and after UsageBoard, with 1, 4 and 19 plans and Close to a limit collapsed and expanded."
  print "Every series runs in processes of its own: CPU time, allocations and peak memory per process."
  print "BENCH_RUNS (default 7 processes per series), BENCH_EVALS (default 300), BENCH_WARMUP (default 30), BENCH_ALLOC_EVALS (default 20), BENCH_RAW=<csv path> for every process."
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
  -o "$OUT/usage-board-bench" \
  "${sources[@]}" scripts/bench/UsageBoardBench.swift 2> "$OUT/usage-board-bench.build.log" || {
    grep -E "error" "$OUT/usage-board-bench.build.log" >&2
    exit 1
  }

commit="$(git rev-parse --short HEAD)"
git diff --quiet HEAD -- Shared scripts/bench/UsageBoardBench.swift scripts/bench-usage-board.sh || commit="$commit with uncommitted changes"

BENCH_COMMIT="$commit" \
BENCH_BUILD="swiftc -O -wmo -swift-version 6, $TARGET, $(swiftc --version 2>/dev/null | head -1)" \
BENCH_HOST="$(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores" \
  "$OUT/usage-board-bench"
