#!/usr/bin/env bash
# Verify the supported emulator-backed userspace boundary and its explicit
# fail-closed physical/unavailable path. Kernel module loading remains a
# separate Kbuild/QEMU authority.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac

tmp=$(mktemp -d /tmp/zag-driver-adapter.XXXXXX)
mkdir -p "$tmp/project"
printf 'name = "driver-adapter-fail-closed"\nversion = "0"\nedition = "2027"\n' >"$tmp/project/zag.mod"
cat >"$tmp/project/main.zag" <<'EOF'
@import("std:driver") as driver
@import("std:driver_linux") as linux
@import("std:driver_linux_userspace") as userspace
@import("std:driver_linux_kernel") as kernel

fn main() i32 {
    let user: userspace.LinuxUserspaceAdapter = userspace.adapter(
        linux.linux_target_x86_64(), linux.linux_kernel_6_1(), 1, 1, 1, 0);
    let module: kernel.LinuxKernelAdapter = kernel.adapter(
        linux.linux_target_x86_64(), linux.linux_kernel_6_1(), 1, 1);
    let unavailable: userspace.LinuxUserspaceAdapter = userspace.adapter(
        linux.linux_target_x86_64(), linux.linux_kernel_6_1(), 0, 0, 0, 0);
    let bad_target: userspace.LinuxUserspaceAdapter = userspace.adapter(
        99, linux.linux_kernel_6_1(), 1, 1, 1, 0);
    let bad_series: userspace.LinuxUserspaceAdapter = userspace.adapter(
        linux.linux_target_x86_64(), 69, 1, 1, 1, 0);
    let bad_module: kernel.LinuxKernelAdapter = kernel.adapter(
        99, linux.linux_kernel_6_1(), 1, 1);
    let probe: driver.DriverStatus = userspace.probe(&user);
    let unavailable_probe: driver.DriverStatus = userspace.probe(&unavailable);
    let bad_target_probe: driver.DriverStatus = userspace.probe(&bad_target);
    let bad_series_probe: driver.DriverStatus = userspace.probe(&bad_series);
    let load: driver.DriverStatus = kernel.load(&module);
    let unload: driver.DriverStatus = kernel.unload(&module);
    let bad_module_load: driver.DriverStatus = kernel.load(&bad_module);
    if (probe.code != driver.driver_ok() ||
        unavailable_probe.code != driver.driver_unsupported() ||
        bad_target_probe.code != driver.driver_invalid_argument() ||
        bad_series_probe.code != driver.driver_invalid_argument() ||
        bad_module_load.code != driver.driver_invalid_argument() ||
        load.code != driver.driver_unsupported() ||
        unload.code != driver.driver_unsupported()) { return 1; }
    return 0;
}
EOF

if ! (cd "$tmp/project" && "$ZNC" main.zag -o out --safety=checked --no-zagd) \
    >"$tmp/build.log" 2>&1; then
  echo 'driver adapters: BLOCKED — fail-closed adapter test did not compile'
  sed -n '1,120p' "$tmp/build.log"
  exit 1
fi
if ! "$tmp/project/out"; then
  echo 'driver adapters: BLOCKED — adapter did not fail closed'
  exit 1
fi
echo 'driver adapters: PASS — unproven Linux acquisition fails closed'
