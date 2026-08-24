#!/usr/bin/env bash
# Compile the same source core for the three initial target spellings.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-driver-targets.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf 'name = "driver-targets"\nversion = "0"\nedition = "2027"\n' >"$tmp/project/zag.mod"
cat >"$tmp/project/main.zag" <<'EOF'
@import("std:driver") as driver
@import("std:driver_linux") as linux
@import("std:driver_linux_userspace") as userspace
@import("std:driver_linux_kernel") as kernel
@import("std:driver_linux_6_1") as linux61
@import("std:driver_linux_6_6") as linux66

fn core_identity(device: @borrows *driver.Device) i64 @driver_control {
    return driver.device_identity(device);
}

fn main() i32 {
    let user: userspace.LinuxUserspaceAdapter = userspace.adapter(
        linux.linux_target_x86_64(), linux61.kernel_series(), 1, 1, 1, 0);
    let module: kernel.LinuxKernelAdapter = kernel.adapter(
        linux.linux_target_x86_64(), linux66.kernel_series(), 1, 1);
    if (userspace.adapter_contract_valid(&user) == 0 ||
        kernel.adapter_contract_valid(&module) == 0 ||
        linux61.kernel_series() != linux.linux_kernel_6_1() ||
        linux66.kernel_series() != linux.linux_kernel_6_6()) { return 98; }
    unsafe {
        let device: driver.Device = driver.device_new_emulated(99);
        let result: i64 = core_identity(&device);
        driver.device_release(device);
        return (result != 99) as i32;
    }
}
EOF

for target in x86-64 arm64 i686; do
  out="$tmp/$target.out"
  log="$tmp/$target.log"
  if [ "$target" = x86-64 ]; then
    args=(main.zag -o "$out" --safety=checked --no-zagd)
  elif [ "$target" = i686 ]; then
    # The existing i686 backend is deliberately a narrow lowering and does not
    # claim the x86-64/ARM64 checked-safety instrumentation.  Driver capability
    # checks still run in the edition-2027 front end; do not smuggle an
    # unsupported safety claim into this target smoke test.
    args=(main.zag -o "$out" --target "$target" --no-zagd)
  else
    args=(main.zag -o "$out" --target "$target" --safety=checked --no-zagd)
  fi
  if (cd "$tmp/project" && "$ZNC" "${args[@]}") >"$log" 2>&1 && [ -e "$out" ]; then
    echo "  ok  common driver core lowers for $target"
  else
    echo "  XX  common driver core does not lower for $target"
    sed -n '1,100p' "$log"
    exit 1
  fi
done

if (cd "$tmp/project" && "$ZNC" main.zag -o "$tmp/unsupported.out" \
    --target riscv64 --no-zagd) >"$tmp/unsupported.log" 2>&1; then
  echo '  XX unsupported target riscv64 was accepted'
  exit 1
fi
if [ -e "$tmp/unsupported.out" ]; then
  echo '  XX unsupported target emitted an artifact'
  exit 1
fi
echo '  ok unsupported target riscv64 rejected before lowering'

echo 'driver target matrix: PASS'
