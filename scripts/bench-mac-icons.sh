#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  print "Usage: ./scripts/bench-mac-icons.sh"
  print "Measures how the Mac app finds and shows provider icons, in this tree and in BENCH_BASE (a git revision, default HEAD~1),"
  print "against the asset catalog Xcode compiles (Assets.car) and the loose files the Command Line Tools build copies."
  print "BENCH_RUNS (default 12) processes per case, BENCH_OUT (default \$TMPDIR/tokenroom-icon-bench) for binaries, raw CSV and pixels."
  print "BENCH_BASE_APP and BENCH_APP take an Xcode-built Tokenroom.app each, to use its Assets.car instead of compiling one with actool."
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${BENCH_OUT:-${TMPDIR:-/tmp}/tokenroom-icon-bench}"
BASE="${BENCH_BASE:-HEAD~1}"
RUNS="${BENCH_RUNS:-12}"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx15.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$OUT"

rm -rf "$OUT/base-tree"
mkdir -p "$OUT/base-tree"
git archive "$BASE" Shared Tokenroom scripts/build.sh | tar -x -C "$OUT/base-tree"

compile() {
  local tree="$1" name="$2"
  local sources=("${(@f)$(find "$tree/Shared" -name '*.swift' -not -path '*/Shared/Widgets/*' | sort)}")
  mkdir -p "$OUT/$name"
  local source="TokenroomImage.named(name, template: template)"
  grep -q 'static func icon(' "$tree/Shared/UI/TokenroomImage.swift" && source="TokenroomImage.icon(name, template: template)"
  print "import AppKit\n\nenum IconSource {\n    static func image(_ name: String, template: Bool) -> NSImage? { $source }\n}" > "$OUT/$name/IconSource.swift"
  swiftc -O -wmo -parse-as-library -swift-version 6 -sdk "$SDK" -target "$TARGET" \
    -o "$OUT/$name/bench" \
    "${sources[@]}" "$tree/Tokenroom/Views/ProviderGlyph.swift" "$OUT/$name/IconSource.swift" "$ROOT/scripts/bench/MacIconBench.swift" \
    2> "$OUT/$name/build.log" || {
      grep -E "error" "$OUT/$name/build.log" >&2
      exit 1
    }
}

loose_images() {
  local tree="$1" res="$2"
  ROOT="$tree" ASSETS="$tree/Tokenroom/Assets.xcassets" zsh -c "
    $(sed -n '/^copy_loose_images() {/,/^}/p' "$tree/scripts/build.sh")
    copy_loose_images '$res'
  "
}

bundle() {
  local tree="$1" name="$2" kind="$3" built="${4:-}"
  local app="$OUT/$name-$kind/TokenroomIconBench.app"
  rm -rf "$OUT/$name-$kind"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$OUT/$name/bench" "$app/Contents/MacOS/TokenroomIconBench"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>TokenroomIconBench</string>
	<key>CFBundleIdentifier</key>
	<string>app.tokenroom.bench.icons</string>
	<key>CFBundleName</key>
	<string>TokenroomIconBench</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST
  if [[ "$kind" == "loose" ]]; then
    loose_images "$tree" "$app/Contents/Resources"
  elif [[ -n "$built" ]]; then
    cp "$built/Contents/Resources/Assets.car" "$app/Contents/Resources/Assets.car"
  else
    xcrun actool "$tree/Shared/UI/ProviderIcons.xcassets" "$tree/Tokenroom/Assets.xcassets" \
      --compile "$app/Contents/Resources" --output-format human-readable-text --notices --warnings \
      --output-partial-info-plist "$OUT/$name-$kind/partial.plist" --enable-on-demand-resources NO \
      --development-region en --target-device mac --minimum-deployment-target 15.0 --platform macosx \
      > "$OUT/$name-$kind/actool.log"
  fi
}

print "Building the bench for $BASE and for this tree"
compile "$OUT/base-tree" base
compile "$ROOT" tree

kinds=(loose)
if xcrun --find actool >/dev/null 2>&1; then
  kinds=(car loose)
else
  print "actool isn't installed: measuring the loose files only"
fi
for kind in $kinds; do
  bundle "$OUT/base-tree" base "$kind" "${BENCH_BASE_APP:-}"
  bundle "$ROOT" tree "$kind" "${BENCH_APP:-}"
done

commit="$(git rev-parse --short HEAD)"
git diff --quiet HEAD -- Shared Tokenroom scripts/bench scripts/bench-mac-icons.sh scripts/build.sh || commit="$commit with uncommitted changes"
{
  print "base: $(git rev-parse --short "$BASE")  tree: $commit"
  print "build: swiftc -O -wmo -swift-version 6, $TARGET, $(swiftc --version 2>/dev/null | head -1)"
  print "host: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)"
  if [[ -n "${BENCH_APP:-}" ]]; then
    print "catalog: Assets.car from ${BENCH_BASE_APP:-actool} (base) and $BENCH_APP (tree)"
  else
    print "catalog: actool, with the arguments Xcode passes"
  fi
} | tee "$OUT/environment.txt"

bench() { "$OUT/$1-$2/TokenroomIconBench.app/Contents/MacOS/TokenroomIconBench" "${@:3}"; }

raw="$OUT/present.csv"
print "variant,catalog,run,set,scale,first_show_wall_ms,cold_cpu_ms,cold_footprint_kb,churn_cpu_ms_per_generation,churn_footprint_kb,churn_sampled_max_kb,tick_cpu_ms_per_tick,final_footprint_kb" > "$raw"
for run in {1..$RUNS}; do
  for kind in $kinds; do
    for set in popover all; do
      for variant in base tree; do
        print "$variant,$kind,$run,$(bench "$variant" "$kind" present --set "$set" | tail -1)" >> "$raw"
      done
    done
  done
done

for kind in $kinds; do
  for variant in base tree; do
    for run in {1..$RUNS}; do
      bench "$variant" "$kind" lookup > "$OUT/lookup-$variant-$kind-$run.csv"
    done
    bench "$variant" "$kind" reps > "$OUT/reps-$variant-$kind.txt"
    rm -rf "$OUT/pixels-$variant-$kind"
    bench "$variant" "$kind" pixels --out "$OUT/pixels-$variant-$kind" > /dev/null
  done
  bench tree "$kind" compare "$OUT/pixels-base-$kind" "$OUT/pixels-tree-$kind" > "$OUT/pixels-$kind.csv"
done

python3 - "$OUT" $kinds <<'SUMMARY' | tee "$OUT/summary.txt"
import csv, statistics, sys

out, kinds = sys.argv[1], sys.argv[2:]
rows = list(csv.DictReader(open(f"{out}/present.csv")))
fields = [
    ("first_show_wall_ms", "first show, wall ms"),
    ("cold_cpu_ms", "cold CPU ms"),
    ("cold_footprint_kb", "cold footprint KB"),
    ("churn_cpu_ms_per_generation", "rebuild CPU ms"),
    ("churn_footprint_kb", "footprint after rebuilds KB"),
    ("churn_sampled_max_kb", "max sampled footprint KB"),
    ("tick_cpu_ms_per_tick", "unrelated update CPU ms"),
]
print()
print("Showing the icons in a window: median [min, max] of one process per run")
for kind in kinds:
    for group in ("popover", "all"):
        print(f"\n{kind}, {group}")
        for key, title in fields:
            cells = []
            medians = {}
            for variant in ("base", "tree"):
                values = [float(r[key]) for r in rows if r["variant"] == variant and r["catalog"] == kind and r["set"] == group]
                medians[variant] = statistics.median(values)
                cells.append(f"{variant} {statistics.median(values):10.2f} [{min(values):.2f}, {max(values):.2f}]")
            change = (medians["tree"] / medians["base"] - 1) * 100 if medians["base"] else 0
            print(f"  {title:30} {cells[0]:40} {cells[1]:40} {change:+7.1f}%")

print("\nFinding one icon, summed over every name: median of one process per run")
import glob
for kind in kinds:
    for variant in ("base", "tree"):
        totals, growth = [], []
        for path in glob.glob(f"{out}/lookup-{variant}-{kind}-*.csv"):
            for line in open(path):
                cells = line.strip().split(",")
                if cells[0] == "total":
                    totals.append([int(cell) for cell in cells[3:7]])
                if cells[0] == "footprint_kb":
                    growth.append(int(cells[3].split("=")[1]))
        first, draw, warm, both = (statistics.median(column) for column in zip(*totals))
        print(f"  {kind:6} {variant:5} first lookup {first / 1e6:8.3f} ms  first draw {draw / 1e6:8.3f} ms  "
              f"warm lookup {warm / 1e3:9.2f} us  warm lookup and draw {both / 1e3:9.2f} us  footprint {statistics.median(growth):8.0f} KB")

print("\nPixels, base against tree (marks at 18 to 40 pt and menu glyphs, 1x and 2x, light and dark)")
for kind in kinds:
    lines = open(f"{out}/pixels-{kind}.csv").read().strip().split("\n")
    print(f"  {kind:6} {lines[-1]}")
SUMMARY
print "\nRaw samples: $raw"
