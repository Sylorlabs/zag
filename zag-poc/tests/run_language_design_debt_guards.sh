#!/usr/bin/env bash
# Cross-language design-debt regression gate for Zag + ZagScript.
#
# This gate intentionally composes existing executable authorities. It protects
# the language boundary and the failure modes we explicitly do not want to
# inherit from C/C++, Rust, Zig, Go, Python, Swift, Java, or Kotlin.
set -eu

cd "$(dirname "$0")/.."

export ZNC=${ZNC:-"$PWD/znc-macos-arm64"}
if [ ! -x "$ZNC" ]; then
    export ZNC="$PWD/znc"
fi

run_required() {
    test -f "$1"
    echo "== language-debt: $1 =="
    bash "$1"
}

# No Python-style rewrite cliff and no profile bleed into strict Zag.
run_required tests/run_zag_zagscript_separation.sh
run_required tests/run_script_python_shape.sh
run_required tests/run_script_cst.sh

# No hidden/unbounded prototype allocation and no ownership-by-convention.
run_required tests/run_script_allocation_accounting.sh
if [ -f tests/run_script_lifetime.sh ]; then
    run_required tests/run_script_lifetime.sh
fi
if [ -f tests/run_v2_try_borrow.sh ]; then
    run_required tests/run_v2_try_borrow.sh
fi
if [ -f tests/run_v2_aggregate_provenance.sh ]; then
    run_required tests/run_v2_aggregate_provenance.sh
fi

# Generic/collection identity and Unicode behavior remain typed and native.
run_required tests/run_collections_unicode.sh
run_required tests/run_script_inference.sh

# Concurrency is language-owned: affine tasks and fail-closed invalid shapes.
run_required tests/run_zagscript_async.sh

# Compile-time/optimizer conveniences are deterministic and bounded.
run_required tests/run_script_auto_lower.sh
run_required tests/run_script_auto_cli.sh

# Promotion is an inspectable continuum rather than a second-language rewrite.
run_required tests/run_script_projection.sh
run_required tests/run_zagscript_views.sh

# Dependency behavior must remain reproducible when the authority suites exist
# on this host. Platform-specific suites are never treated as passing by skip.
if [ -f tests/run_package_resolution.sh ]; then
    run_required tests/run_package_resolution.sh
fi
if [ -f tests/run_package_lock_generator.sh ]; then
    run_required tests/run_package_lock_generator.sh
fi

echo 'Zag/ZagScript cross-language design-debt guards: PASS'
