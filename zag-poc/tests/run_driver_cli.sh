#!/usr/bin/env bash
# Fresh compiler integration gate for the typed Linux driver-module CLI.
# This proves compiler-produced ET_REL output; Kbuild final linking and QEMU
# lifecycle evidence remain separate release gates.
set -eu
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
case "$compiler" in
  /*) ;;
  *) compiler="$PWD/${compiler#./}" ;;
esac
if [ ! -x "$compiler" ]; then
  echo 'driver CLI: BLOCKED — ZNC must name an executable compiler'
  exit 1
fi

tmp=$(mktemp -d /tmp/zag-driver-cli-gate.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf 'name = "driver-cli"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
cp tests/fixtures/driver_module_cli.zag "$tmp/main.zag"

for target in x86_64 arm64 i686; do
  case "$target" in
    x86_64) series=6.1; series_tag=6_1 ;;
    arm64) series=6.6; series_tag=6_6 ;;
    i686) series=6.1; series_tag=6_1 ;;
  esac
  out="$tmp/$target.o"
  log="$tmp/$target.log"
  if ! (cd "$tmp" && "$compiler" main.zag \
      --emit-driver-module --driver-kernel "$series" --target "$target" \
      -o "$out" --no-zagd --no-analyze --no-foreground-cache) >"$log" 2>&1; then
    echo "driver CLI: BLOCKED — integrated $target module lowering failed"
    sed -n '1,100p' "$log"
    exit 1
  fi
  ZAG_DRIVER_MODULE="$out" \
    ZAG_DRIVER_MODULE_TARGET="$target" \
    ZAG_DRIVER_MODULE_KERNEL_SERIES="$series_tag" \
    bash tests/check_driver_kernel_object.sh
  cp "$out" "$tmp/$target.first.o"
done

# The same source and compiler image must produce byte-identical objects.
for target in x86_64 arm64 i686; do
  case "$target" in
    x86_64) series=6.1 ;;
    arm64) series=6.6 ;;
    i686) series=6.1 ;;
  esac
  (cd "$tmp" && "$compiler" main.zag \
      --emit-driver-module --driver-kernel "$series" --target "$target" \
      -o "$target.second.o" --no-zagd --no-analyze --no-foreground-cache \
      >"$target.second.log" 2>&1)
  if ! cmp -s "$tmp/$target.first.o" "$tmp/$target.second.o"; then
    echo "driver CLI: BLOCKED — nondeterministic $target ET_REL output"
    exit 1
  fi
done

# Unsupported kernel bindings must fail before an artifact is emitted.
set +e
(cd "$tmp" && "$compiler" main.zag --emit-driver-module \
    --driver-kernel 6.5 --target x86_64 -o unsupported.o \
    --no-zagd --no-analyze --no-foreground-cache) >"$tmp/unsupported.log" 2>&1
unsupported_rc=$?
set -e
if [ "$unsupported_rc" -eq 0 ] || [ -e "$tmp/unsupported.o" ]; then
  echo 'driver CLI: BLOCKED — unsupported Linux series was accepted'
  sed -n '1,80p' "$tmp/unsupported.log"
  exit 1
fi

set +e
(cd "$tmp" && "$compiler" main.zag --emit-driver-module \
    --driver-kernel 6.1 --target riscv64 -o unsupported-target.o \
    --no-zagd --no-analyze --no-foreground-cache) >"$tmp/unsupported-target.log" 2>&1
unsupported_target_rc=$?
set -e
if [ "$unsupported_target_rc" -eq 0 ] || [ -e "$tmp/unsupported-target.o" ]; then
  echo 'driver CLI: BLOCKED — unsupported target was accepted'
  sed -n '1,80p' "$tmp/unsupported-target.log"
  exit 1
fi

echo 'driver CLI: PASS — fresh compiler emitted deterministic x86-64, arm64, and i686 ET_REL modules'
