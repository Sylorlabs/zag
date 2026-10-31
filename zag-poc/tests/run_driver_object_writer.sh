#!/usr/bin/env bash
# Execute the standalone pure-Zag kernel ET_REL writer against all initial
# ELF targets. This is structural compiler/lowering evidence; Kbuild and QEMU
# remain separate gates and are never inferred from this harness.
set -eu
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
if [ ! -x "$compiler" ]; then
  echo 'driver object writer: BLOCKED — ZNC must name an executable compiler'
  exit 1
fi

tmp=$(mktemp -d /tmp/zag-driver-object-writer.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

if ! "$compiler" selfhost/native/driver_elf_source_test.zag \
    -o "$tmp/writer" --no-zagd --no-analyze --no-foreground-cache \
    >"$tmp/build.log" 2>&1; then
  echo 'driver object writer: BLOCKED — source-level writer harness did not compile'
  sed -n '1,80p' "$tmp/build.log"
  exit 1
fi
if ! "$tmp/writer" >"$tmp/run.log" 2>&1; then
  echo 'driver object writer: BLOCKED — writer harness failed'
  sed -n '1,80p' "$tmp/run.log"
  exit 1
fi

for target in x86_64 arm64 i686; do
  case "$target" in
    x86_64) object=/tmp/driver-elf-source-test-x86_64.o; series=6_1 ;;
    arm64) object=/tmp/driver-elf-source-test-arm64.o; series=6_6 ;;
    i686) object=/tmp/driver-elf-source-test-i686.o; series=6_1 ;;
  esac
  if [ ! -f "$object" ]; then
    echo "driver object writer: BLOCKED — missing generated $target ET_REL"
    exit 1
  fi
  ZAG_DRIVER_MODULE="$object" \
    ZAG_DRIVER_MODULE_TARGET="$target" \
    ZAG_DRIVER_MODULE_KERNEL_SERIES="$series" \
    bash tests/check_driver_kernel_object.sh
  cp "$object" "$tmp/$target.first.o"
done

# Run a second independent generation and require deterministic bytes.
if ! "$tmp/writer" >"$tmp/run-second.log" 2>&1; then
  echo 'driver object writer: BLOCKED — second writer run failed'
  exit 1
fi
for target in x86_64 arm64 i686; do
  if ! cmp -s "/tmp/driver-elf-source-test-$target.o" "$tmp/$target.first.o"; then
    echo "driver object writer: BLOCKED — nondeterministic $target object"
    exit 1
  fi
done
echo 'driver object writer: PASS — x86-64, arm64, and i686 ET_REL output is deterministic and structurally checked'
