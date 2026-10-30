#!/usr/bin/env bash
# SOURCE-ONLY / UNCOMPILED / UNEXECUTED
# From zag-poc: bash research/tomo-cache-source-edit-repro.sh
# Requires a locally built ./znc (or ZNC=/absolute/path/to/znc), sha256sum.
# Isolated temporary directory; neither repository files nor existing cache
# are modified. Retains logs, sources and binaries for review.
set -u
compiler=${ZNC:-./znc}
if [ ! -x "$compiler" ]; then printf 'Missing compiler: %s\n' "$compiler" >&2; exit 2; fi
compiler=$(realpath "$compiler")
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-cache-edit.XXXXXXXX") || exit 2
cd "$work" || exit 2
printf 'Evidence: %s\nCompiler SHA-256:\n' "$work"
sha256sum "$compiler" | tee compiler.sha256
cat >main.zag <<'EOF'
@import("dep.zag")
fn main() i32 { return cached_value(); }
EOF
cat >dep.zag <<'EOF'
fn cached_value() i32 { return 42; }
EOF
# Same command, arguments, cwd, source and output paths for all cached builds.
build() { "$compiler" main.zag -o app --cache-report --no-zagd; }
run_status() { "$1" >/dev/null 2>&1; printf '%s\n' "$?"; }
sha256sum main.zag dep.zag > sources-before.sha256
build >cold.log 2>&1 || { echo 'cold build failed; see cold.log'; exit 2; }
cp app before-app
before=$(run_status ./app)
build >warm.log 2>&1 || { echo 'warm build failed; see warm.log'; exit 2; }
warm=$(run_status ./app)
cp app warm-app
# Edit a semantic token in the imported module, preserving names and command.
cat >dep.zag <<'EOF'
fn cached_value() i32 { return 43; }
EOF
sha256sum main.zag dep.zag > sources-after.sha256
build >edited.log 2>&1 || { echo 'edited build failed; see edited.log'; exit 2; }
cp app edited-app
after=$(run_status ./app)
# Independent no-foreground-cache control, same edited source.
"$compiler" main.zag -o fresh-app --cache-report --no-zagd --no-foreground-cache >fresh.log 2>&1 || { echo 'fresh build failed; see fresh.log'; exit 2; }
fresh=$(run_status ./fresh-app)
sha256sum before-app warm-app edited-app fresh-app > binaries.sha256
printf 'exit status: cold=%s warm=%s edited=%s fresh=%s\n' "$before" "$warm" "$after" "$fresh"
printf '%s\n' 'Source hashes:'; cat sources-before.sha256 sources-after.sha256
printf '%s\n' 'Binary hashes:'; cat binaries.sha256
printf '%s\n' 'Cache reports:'; grep 'znc cache:' cold.log warm.log edited.log fresh.log || true
# Functional check: changed source must yield 43 and match fresh compilation.
# Hash differences alone do not prove stale output, and equal hashes on an
# edit whose observable program output changes require investigation.
if [ "$before" != 42 ] || [ "$warm" != 42 ] || [ "$fresh" != 43 ]; then
  echo 'INCONCLUSIVE: baseline or fresh control failed'; exit 2
fi
if [ "$after" != 43 ]; then
  echo 'STALE OUTPUT OBSERVED: cached edited build disagrees with fresh control'; exit 1
fi
if cmp -s before-app edited-app; then
  echo 'INCONCLUSIVE: outputs unexpectedly identical despite changed exit status'; exit 2
fi
echo 'PASS: this semantic imported-source edit did not reuse stale behavior'
# Source inspection: cache key includes compiler version, semantic graph and
# policy, and the graph uses token identity. This one test cannot establish
# complete coverage of all inputs, paired options or all compiler identities.
# A stale-build defect has NOT been reproduced by source inspection alone.
