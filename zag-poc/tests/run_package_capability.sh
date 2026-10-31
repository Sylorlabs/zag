#!/usr/bin/env bash
# Frozen ZagScript 1.0 package-resolution authority.
#
# This is the single evidence entry for the declared local-first package
# contract: canonical lock generation, offline/vendor resolution, raw-byte
# checksums and cache provenance, conflict/version diagnostics, local registry
# selection, detached Ed25519 index verification, and opt-in selected-artifact
# signatures. Network fetching, revision solving, and broad artifact-signature
# policy are intentionally outside this Linux x86-64 1.0 contract.
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-"$PWD/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/${compiler#./}" ;;
esac
if [[ ! -x "$compiler" ]]; then
    printf 'package capability compiler is not executable: %s\n' "$compiler" >&2
    exit 1
fi

pass=0
run_case() {
    local name=$1
    shift
    printf '── package case: %s\n' "$name"
    "$@"
    pass=$((pass + 1))
}

run_case 'offline resolver and lock provenance' \
    bash tests/run_package_resolution.sh
run_case 'no-clean reproducibility contract' \
    bash tests/run_package_resolution_noclean.sh
run_case 'create-only lock generation' \
    bash tests/run_package_lock_generator.sh
run_case 'canonical local registry protocol' \
    bash tests/run_package_registry.sh
run_case 'detached package-index signatures' \
    bash tests/run_package_signature.sh
run_case 'signed registry selection' \
    bash tests/run_package_signed_resolver.sh
run_case 'registry lock signature provenance' \
    bash tests/run_package_registry_lock.sh
run_case 'foreground registry lock selection' \
    bash tests/run_package_registry_lock_resolve.sh
run_case 'create-only registry lock generation' \
    bash tests/run_package_registry_lock_generator.sh
run_case 'opt-in sibling lock provenance' \
    bash tests/run_package_sibling_lock.sh
run_case 'strict resolver source authority' \
    "$compiler" check selfhost/package_resolve.zag --analyze-strict \
        --no-zagd --no-foreground-cache

test "$pass" -eq 11
printf 'package capability: pass=%d fail=0\n' "$pass"
