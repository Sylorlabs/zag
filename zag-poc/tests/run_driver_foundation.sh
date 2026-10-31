#!/usr/bin/env bash
# Release gate for the unified std:driver foundation.
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zag-driver-foundation.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
evidence="$tmp/evidence"
mkdir -p "$evidence"

echo '── driver foundation: self-host bootstrap reproducibility ──'
bash tests/check_native_bootstrap_repro.sh

echo '── driver foundation: typed contract and negative capability tests ──'
bash tests/run_driver_contract.sh
touch "$evidence/contract.pass"

echo '── driver foundation: binary layout and unaligned-access diagnostics ──'
bash tests/run_driver_layout.sh
touch "$evidence/layout.pass"
bash tests/run_driver_layout_targets.sh
touch "$evidence/layout_targets.pass"

echo '── driver foundation: generic emulator corpus ──'
bash tests/run_driver_emulator.sh
touch "$evidence/emulator.pass"
bash tests/run_driver_property.sh
touch "$evidence/property.pass"

echo '── driver foundation: Linux userspace adapter and fail-closed physical boundary ──'
bash tests/run_driver_adapter_fail_closed.sh
touch "$evidence/adapter_fail_closed.pass"
bash tests/run_driver_userspace_matrix.sh
for series in 6_1 6_6; do
  for target in x86_64 arm64 i686; do
    touch "$evidence/userspace_${series}_${target}.pass"
  done
done

echo '── driver foundation: deterministic target ET_REL lowering ──'
bash tests/run_driver_cli.sh
touch "$evidence/cli_object_writer.pass"
bash tests/run_driver_object_writer.sh
touch "$evidence/object_writer.pass"

echo '── driver foundation: kernel-owned Kbuild handoff contract ──'
ZAG_DRIVER_KBUILD="$PWD/tests/fixtures/driver.Kbuild" bash tests/check_driver_kbuild_contract.sh
touch "$evidence/kbuild_fixture.pass"

echo '── driver foundation: common-core target lowering ──'
bash tests/run_driver_target_matrix.sh
for series in 6_1 6_6; do
  for target in x86_64 arm64 i686; do
    touch "$evidence/core_${series}_${target}.pass"
  done
done

echo '── driver foundation: checked-in i686 backend source smoke ──'
bash tests/run_driver_i686_source_backend.sh
touch "$evidence/i686_source_backend.pass"

echo '── driver foundation: checked-in ARM64 backend source smoke ──'
bash tests/run_driver_arm64_source_backend.sh
touch "$evidence/arm64_source_backend.pass"

echo '── driver foundation: relocatable kernel object and six-row QEMU matrix ──'
# The QEMU gate is deliberately the final authority. When an exact kernel root
# is supplied, build_driver_matrix performs the real Kbuild link and creates
# native initramfs rows before running QEMU. Without it, the supplied-row gate
# still fails closed; emulator evidence never substitutes for a missing row.
if [ -n "${ZAG_DRIVER_KERNEL_ROOT-}" ]; then
  if ! ZAG_DRIVER_EVIDENCE_DIR="$evidence" bash tests/run_driver_matrix_build.sh; then
    echo 'driver foundation: RELEASE BLOCKED — kernel-object/QEMU evidence is incomplete'
    ZAG_DRIVER_EVIDENCE_DIR="$evidence" bash tests/generate_driver_support_matrix.sh
    exit 1
  fi
elif ! ZAG_DRIVER_EVIDENCE_DIR="$evidence" bash tests/run_driver_qemu_matrix.sh; then
  echo 'driver foundation: RELEASE BLOCKED — kernel-object/QEMU evidence is incomplete'
  ZAG_DRIVER_EVIDENCE_DIR="$evidence" bash tests/generate_driver_support_matrix.sh
  exit 1
fi

for series in 6_1 6_6; do
  for target in x86_64 arm64 i686; do
    touch "$evidence/module_${series}_${target}.pass"
    touch "$evidence/kbuild_${series}_${target}.pass"
    touch "$evidence/qemu_${series}_${target}.pass"
  done
done

echo '── driver foundation: truthful support-matrix generation ──'
generated_matrix="$tmp/driver-support-matrix.generated.md"
ZAG_DRIVER_EVIDENCE_DIR="$evidence" bash tests/generate_driver_support_matrix.sh >"$generated_matrix"
if diff -u docs/DRIVER_SUPPORT_MATRIX.generated.md "$generated_matrix"; then
  echo '  ok  checked-in driver support matrix matches all six executable rows'
else
  echo '  XX  checked-in driver support matrix is stale'
  exit 1
fi
echo 'driver foundation: PASS'
