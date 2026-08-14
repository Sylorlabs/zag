#!/usr/bin/env bash
# Generic virtual-device lifecycle, fault, and invariant corpus.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-driver-emulator.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf 'name = "driver-emulator"\nversion = "0"\nedition = "2027"\n' >"$tmp/project/zag.mod"
cat >"$tmp/project/main.zag" <<'EOF'
@import("std:driver") as driver
@import("std:driver_emulator") as emulator

fn main() i32 {
    if (emulator.emulator_run_fault_status() != 1) { return 20; }
    let device: emulator.EmulatorDevice = emulator.emulator_new(128, driver.endian_little(), 16);
    let little_write: driver.DriverStatus = emulator.emulator_mmio_write_width(
        &device, 4, driver.mmio_width_16(), 0x1234);
    let little_read: emulator.EmulatorResult = emulator.emulator_mmio_read_width(
        &device, 4, driver.mmio_width_16());
    if (little_write.code != driver.driver_ok() || little_read.status != driver.driver_ok() ||
        little_read.value != 0x1234 || emulator.emulator_register_raw_value(&device) != 0x1234) {
        return 1;
    }
    let big: emulator.EmulatorDevice = emulator.emulator_new(128, driver.endian_big(), 16);
    let big_write: driver.DriverStatus = emulator.emulator_mmio_write_width(
        &big, 4, driver.mmio_width_16(), 0x1234);
    let big_read: emulator.EmulatorResult = emulator.emulator_mmio_read_width(
        &big, 4, driver.mmio_width_16());
    if (big_write.code != driver.driver_ok() || big_read.status != driver.driver_ok() ||
        big_read.value != 0x1234 || emulator.emulator_register_raw_value(&big) != 0x3412) {
        return 2;
    }
    let bounds: emulator.EmulatorDevice = emulator.emulator_new(128, driver.endian_little(), 16);
    let bad_width: driver.DriverStatus = emulator.emulator_mmio_write_width(
        &bounds, 3, driver.mmio_width_32(), 1);
    if (bad_width.code != driver.driver_out_of_range()) { return 3; }
    let status: driver.DriverStatus = emulator.emulator_dma_map(&device, 2, 64);
    if (status.code != driver.driver_ok()) { return 4; }
    let handoff: driver.DriverStatus = emulator.emulator_dma_handoff(&device, 4);
    if (handoff.code != driver.driver_ok()) { return 5; }
    let complete: driver.DriverStatus = emulator.emulator_dma_complete(&device, 2);
    if (complete.code != driver.driver_ok()) { return 6; }
    let complete_remaining: driver.DriverStatus = emulator.emulator_dma_complete(&device, 2);
    let complete_again: driver.DriverStatus = emulator.emulator_dma_complete(&device, 1);
    let unmapped: driver.DriverStatus = emulator.emulator_dma_unmap(&device, 2);
    if (complete_remaining.code != driver.driver_ok() ||
        complete_again.code != driver.driver_stale_handle() || unmapped.code != driver.driver_ok()) {
        return 19;
    }
    let saturated: emulator.EmulatorDevice = emulator.emulator_new(
        128, driver.endian_little(), 4);
    let saturation_map: driver.DriverStatus = emulator.emulator_dma_map(
        &saturated, 1, 64);
    let saturation_fill: driver.DriverStatus = emulator.emulator_dma_handoff(
        &saturated, 4);
    let saturation_retry: driver.DriverStatus = emulator.emulator_dma_handoff(
        &saturated, 1);
    let saturation_drain: driver.DriverStatus = emulator.emulator_dma_complete(
        &saturated, 4);
    let saturation_unmap: driver.DriverStatus = emulator.emulator_dma_unmap(
        &saturated, 1);
    let saturation_snapshot: emulator.EmulatorResult = emulator.emulator_snapshot(
        &saturated);
    if (saturation_map.code != driver.driver_ok() ||
        saturation_fill.code != driver.driver_ok() ||
        saturation_retry.code != driver.driver_busy() ||
        saturation_drain.code != driver.driver_ok() ||
        saturation_unmap.code != driver.driver_ok() ||
        saturation_snapshot.invariant_failures != 0) {
        return 26;
    }
    let irq: driver.DriverStatus = emulator.emulator_irq_raise(&device, 1);
    if (irq.code != driver.driver_ok()) { return 7; }
    let ack: driver.DriverStatus = emulator.emulator_irq_ack(&device);
    if (ack.code != driver.driver_ok()) { return 8; }
    let reset: driver.DriverStatus = emulator.emulator_reset(&device);
    if (reset.code != driver.driver_ok()) { return 9; }
    let malformed: driver.DriverStatus = emulator.emulator_malformed_descriptor(&device);
    if (malformed.code != driver.driver_invalid_argument()) { return 10; }
    let stale: driver.DriverStatus = emulator.emulator_stale_completion(&device);
    if (stale.code != driver.driver_stale_handle()) { return 11; }
    let reordered: driver.DriverStatus = emulator.emulator_reordered_completion(&device);
    if (reordered.code != driver.driver_busy()) { return 12; }
    let reset_again: driver.DriverStatus = emulator.emulator_reset(&device);
    if (reset_again.code != driver.driver_ok()) { return 13; }
    let suspend: driver.DriverStatus = emulator.emulator_suspend(&device);
    let resume: driver.DriverStatus = emulator.emulator_resume(&device);
    if (suspend.code != driver.driver_ok() || resume.code != driver.driver_ok()) { return 14; }
    let unplug: driver.DriverStatus = emulator.emulator_hot_unplug(&device);
    if (unplug.code != driver.driver_ok()) { return 15; }
    let after: driver.DriverStatus = emulator.emulator_mmio_write(&device, 0, 1);
    if (after.code != driver.driver_quiescing()) { return 16; }
    let teardown: driver.DriverStatus = emulator.emulator_teardown(&device);
    if (teardown.code != driver.driver_ok()) { return 17; }
    let snapshot: emulator.EmulatorResult = emulator.emulator_snapshot(&device);
    if (snapshot.invariant_failures != 0) { return 18; }
    return 0;
}
EOF

if (cd "$tmp/project" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/build.log" 2>&1 && [ -x "$tmp/project/out" ]; then
  set +e
  "$tmp/project/out"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  XX  emulator lifecycle corpus (exit=$rc)"
    sed -n '1,120p' "$tmp/build.log"
    exit 1
  fi
  echo '  ok  generic emulator covers DMA, IRQ, reset, power, unplug, stale, and teardown invariants'
else
  echo '  XX  emulator corpus did not compile'
  sed -n '1,160p' "$tmp/build.log"
  exit 1
fi

echo 'driver emulator: PASS'
