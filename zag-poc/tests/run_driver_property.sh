#!/usr/bin/env bash
# Deterministic generic emulator differential/property corpus.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-driver-property.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf 'name = "driver-property"
version = "0"
edition = "2027"
' >"$tmp/project/zag.mod"
cat >"$tmp/project/main.zag" <<'EOF'
@import("std:driver_emulator") as emulator

fn main() i32 {
    let seed: i32 = 0;
    while (seed < 32) {
        let result: emulator.EmulatorCorpusResult = emulator.emulator_run_differential(seed * 7919 + 17, 192);
        if (result.invariant_failures != 0 || result.steps != 192) { return 1; }
        seed = seed + 1;
    }
    return 0;
}
EOF

if (cd "$tmp/project" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/build.log" 2>&1 && [ -x "$tmp/project/out" ]; then
  set +e
  "$tmp/project/out"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  XX  deterministic emulator property corpus (exit=$rc)"
    sed -n '1,120p' "$tmp/build.log"
    exit 1
  fi
  echo '  ok  deterministic differential corpus preserves emulator invariants'
else
  echo '  XX  deterministic emulator property corpus did not compile'
  sed -n '1,160p' "$tmp/build.log"
  exit 1
fi

echo 'driver property: PASS'
