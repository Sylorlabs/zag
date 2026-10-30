#!/usr/bin/env bash
# SOURCE-ONLY / UNCOMPILED / UNEXECUTED. From zag-poc:
#   bash research/tomo-numeric-matrix-2026-10-30.sh
# Use a built ./znc or set ZNC to an executable compiler path.
# Edition-2026 currently has a backend-owned numeric conversion extension.
# Proposal, not current law: an edition/policy-gated diagnostic for implicit
# loss of representable range, while allowing supported explicit conversions.
# A v2 design rule is not automatically an edition-2026 requirement.
set -u
ZNC=${ZNC:-./znc}
if [ ! -x "$ZNC" ]; then echo "missing compiler: $ZNC" >&2; exit 2; fi
ZNC=$(realpath "$ZNC")
D=$(mktemp -d "${TMPDIR:-/tmp}/zag-numeric-matrix.XXXXXXXX") || exit 2
printf 'Evidence directory: %s\nCompiler SHA-256:\n' "$D"
sha256sum "$ZNC" || exit 2
"$ZNC" --version || true
# Each test is compiled independently. A nonzero build exit is meaningful
# only when the log identifies the conversion rather than unrelated syntax.
casefile() { printf 'fn main() i32 {\n    %s\n    return 0;\n}\n' "$2" > "$D/$1.zag"; }
casefile signed_narrow 'let x: i64 = 42; let y: i32 = x;'
casefile unsigned_narrow 'let x: u64 = 42; let y: u32 = x;'
casefile signed_widen 'let x: i32 = 42; let y: i64 = x;'
casefile unsigned_widen 'let x: u32 = 42; let y: u64 = x;'
casefile signed_to_unsigned 'let x: i32 = 42; let y: u32 = x;'
casefile unsigned_to_signed_wider 'let x: u32 = 42; let y: i64 = x;'
casefile mixed_add 'let x: i64 = 42; let y: i32 = 1; let z: i64 = x + y;'
casefile explicit_signed_narrow 'let x: i64 = 42; let y: i32 = x as i32;'
casefile explicit_unsigned_narrow 'let x: u64 = 42; let y: u32 = x as u32;'
printf 'case\tcompile_exit\trun_exit\n'
for name in signed_narrow unsigned_narrow signed_widen unsigned_widen signed_to_unsigned unsigned_to_signed_wider mixed_add explicit_signed_narrow explicit_unsigned_narrow; do
  "$ZNC" "$D/$name.zag" --no-zagd --no-foreground-cache -o "$D/$name" >"$D/$name.build.log" 2>&1
  build=$?
  run=not_run
  if [ "$build" -eq 0 ] && [ -x "$D/$name" ]; then
    "$D/$name" >"$D/$name.run.log" 2>&1
    run=$?
    sha256sum "$D/$name" >"$D/$name.bin.sha256"
  fi
  printf '%s\t%s\t%s\n' "$name" "$build" "$run"
done
sha256sum "$D"/*.zag > "$D/source.sha256"
printf 'Inspect logs under %s; observations are not a policy verdict.\n' "$D"
# Widening and explicit casts are controls; mixed arithmetic and signedness
# need a separately agreed policy. Verify cast syntax against this compiler.
# Add runtime boundary-value checks before proposing or accepting a patch.
