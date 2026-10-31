#!/usr/bin/env bash
# Shared-core and compiler-authority contract gate for std:driver.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-driver-contract.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

make_case() {
  mkdir -p "$tmp/$1"
  printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$tmp/$1/zag.mod"
}

compile_positive() {
  make_case positive
  cat >"$tmp/positive/main.zag" <<'EOF'
@import("std:driver") as driver
@import("std:driver_emulator") as emulator
@import("std:driver_linux") as linux
@import("std:driver_linux_userspace") as userspace
@import("std:driver_linux_kernel") as kernel
@import("std:driver_linux_kbuild") as kbuild
@import("std:driver_linux_6_1") as linux61
@import("std:driver_linux_6_6") as linux66

@linux_api(66,1,5,256,3)
fn tagged_probe_contract() i32 { return linux.linux_api_pci_probe(); }

fn main() i32 {
    unsafe {
        let device: driver.Device = driver.device_new_emulated(7);
        let identity: i64 = driver.device_identity(&device);
        let adapter: i32 = driver.device_adapter(&device);
        driver.device_release(device);
        if (identity != 7 || adapter != 1) { return 10; }
    }
    let virtual: emulator.EmulatorDevice = emulator.emulator_new(64, driver.endian_little(), 8);
    let mapped: emulator.EmulatorResult = emulator.emulator_snapshot(&virtual);
    if (mapped.invariant_failures != 0) { return 11; }
    let tag: linux.LinuxInterfaceTag = linux.linux_interface_tag(
        linux.linux_kernel_6_6(), linux.linux_api_pci_probe(),
        linux.linux_context_probe(), linux.linux_api_effects(linux.linux_api_pci_probe()),
        linux.linux_api_ownership(linux.linux_api_pci_probe()));
    if (linux.linux_interface_available(&tag) == 0) { return 12; }
    if (linux61.kernel_series() != linux.linux_kernel_6_1() ||
        linux66.kernel_series() != linux.linux_kernel_6_6()) { return 13; }
    if (linux61.pci_probe_binding() != linux.linux_api_pci_probe() ||
        linux61.irq_request_binding() != linux.linux_api_irq_request() ||
        linux66.dma_map_binding() != linux.linux_api_dma_map() ||
        linux66.pm_resume_binding() != linux.linux_api_pm_resume()) { return 26; }
    let user_adapter: userspace.LinuxUserspaceAdapter = userspace.adapter(
        linux.linux_target_x86_64(), linux.linux_kernel_6_6(), 1, 1, 1, 0);
    let kernel_adapter: kernel.LinuxKernelAdapter = kernel.adapter(
        linux.linux_target_x86_64(), linux.linux_kernel_6_6(), 1, 1);
    if (userspace.adapter_contract_valid(&user_adapter) == 0 ||
        kernel.adapter_contract_valid(&kernel_adapter) == 0) { return 14; }
    let field: driver.RegisterField = driver.register_field_new(
        driver.mmio_width_32(), 4, 4, driver.endian_little());
    let encoded: u64 = driver.register_field_insert(&field, 0, 11);
    if (driver.register_field_extract(&field, encoded) != 11 ||
        driver.register_field_mask(&field) != 240) { return 15; }
    let big_field: driver.RegisterField = driver.register_field_new(
        driver.mmio_width_16(), 4, 4, driver.endian_big());
    let big_encoded: u64 = driver.register_field_insert(&big_field, 0x1200, 11);
    if (big_encoded != 0xb012 ||
        driver.register_field_extract(&big_field, big_encoded) != 11) { return 24; }
    let descriptor_field: driver.DescriptorField = driver.descriptor_field_new(
        16, 4, driver.mmio_width_16(), driver.endian_big());
    let descriptor_bus: u64 = driver.descriptor_field_encode(&descriptor_field, 0x1234);
    if (driver.descriptor_field_is_valid(&descriptor_field) == 0 || descriptor_bus != 0x3412 ||
        driver.descriptor_field_decode(&descriptor_field, descriptor_bus) != 0x1234) { return 27; }
    unsafe {
        let register: driver.MmioRegister[u16] = driver.mmio_register_new_emulated[u16](
            4, driver.mmio_width_16(), driver.mmio_read_write(),
            driver.endian_big(), driver.mmio_barrier_device());
        let register_write: driver.DriverStatus = driver.mmio_write16(&register, 0x1234);
        let register_read: driver.MmioRead16 = driver.mmio_read16(&register);
        let register_rmw: driver.DriverStatus = driver.mmio_rmw16(&register, 0x00ff, 0x0056);
        let register_after: driver.MmioRead16 = driver.mmio_read16(&register);
        driver.mmio_register_release(register);
        if (register_write.code != driver.driver_ok() || register_read.status != driver.driver_ok() ||
            register_read.value != 0x1234 || register_rmw.code != driver.driver_ok() ||
            register_after.value != 0x1256) { return 17; }
        let invalid_register: driver.MmioRegister[u16] = driver.mmio_register_new_emulated[u16](
            4, driver.mmio_width_16(), driver.mmio_read_write(), 99, 99);
        let invalid_write: driver.DriverStatus = driver.mmio_write16(&invalid_register, 1);
        driver.mmio_register_release(invalid_register);
        if (invalid_write.code != driver.driver_invalid_argument()) { return 22; }
        let counter: driver.Atomic[u32] = driver.atomic_new_emulated[u32](32, 1);
        let atomic_store: driver.DriverStatus = driver.atomic_store32(
            &counter, 0x55aa, driver.order_release());
        let atomic_load: driver.AtomicRead32 = driver.atomic_load32(
            &counter, driver.order_acquire());
        let exchanged: driver.AtomicRead32 = driver.atomic_exchange32(
            &counter, 0x55ff, driver.order_acq_rel());
        let added: driver.AtomicRead32 = driver.atomic_fetch_add32(
            &counter, 1, driver.order_seq_cst());
        let masked: driver.AtomicRead32 = driver.atomic_fetch_and32(
            &counter, 0xffff, driver.order_relaxed());
        let compared: driver.AtomicCompare32 = driver.atomic_compare_exchange32(
            &counter, 0x5600, 0x1234, driver.order_acq_rel(), driver.order_acquire());
        let compare_failed: driver.AtomicCompare32 = driver.atomic_compare_exchange32(
            &counter, 0x9999, 0x5678, driver.order_seq_cst(), driver.order_relaxed());
        let fence: driver.DriverStatus = driver.atomic_fence(driver.order_seq_cst());
        driver.atomic_release(counter);
        if (atomic_store.code != driver.driver_ok() || atomic_load.status != driver.driver_ok() ||
            atomic_load.value != 0x55aa || exchanged.status != driver.driver_ok() ||
            exchanged.value != 0x55aa || added.status != driver.driver_ok() ||
            added.value != 0x55ff || masked.status != driver.driver_ok() ||
            masked.value != 0x5600 || compared.status != driver.driver_ok() ||
            compared.observed != 0x5600 || compared.exchanged != 1 ||
            compare_failed.status != driver.driver_ok() || compare_failed.observed != 0x1234 ||
            compare_failed.exchanged != 0 || fence.code != driver.driver_unsupported()) { return 18; }
        let lock: driver.DriverMutex = driver.driver_mutex_new_emulated(1);
        let try_lock: driver.DriverStatus = driver.driver_mutex_try_lock(&lock);
        let blocked: driver.DriverStatus = driver.driver_mutex_lock(&lock);
        let unlock: driver.DriverStatus = driver.driver_mutex_unlock(&lock);
        let lock_again: driver.DriverStatus = driver.driver_mutex_lock(&lock);
        let unlock_again: driver.DriverStatus = driver.driver_mutex_unlock(&lock);
        driver.driver_mutex_release(lock);
        if (try_lock.code != driver.driver_ok() || blocked.code != driver.driver_busy() ||
            unlock.code != driver.driver_ok() || lock_again.code != driver.driver_ok() ||
            unlock_again.code != driver.driver_ok()) { return 21; }
        let irq: driver.IrqHandle = driver.irq_new_emulated(7, driver.irq_threaded());
        let irq_register: driver.DriverStatus = driver.irq_register(&irq);
        let irq_defer: driver.DriverStatus = driver.irq_defer_work(&irq);
        let irq_run: driver.DriverStatus = driver.irq_run_deferred(&irq);
        let irq_unregister: driver.DriverStatus = driver.irq_unregister(&irq);
        driver.irq_release(irq);
        if (irq_register.code != driver.driver_ok() || irq_defer.code != driver.driver_ok() ||
            irq_run.code != driver.driver_ok() || irq_unregister.code != driver.driver_ok()) { return 23; }
        let domain: driver.DmaDomain = driver.dma_domain_new_emulated(64, 4, driver.dma_coherent());
        let buffer: driver.DmaBuffer[u8] = driver.dma_buffer_new_emulated[u8](
            16, 64, driver.dma_bidirectional(), driver.dma_coherent());
        let address: driver.BusAddress = driver.dma_buffer_map_emulated[u8](
            &buffer, &domain, 0x1000, 1);
        let sync_device: driver.DriverStatus = driver.dma_buffer_sync_for_device[u8](&buffer);
        // znc:allow A0102 -- @consumes BusAddress requires a standalone call.
        driver.dma_buffer_unmap[u8](&buffer, address);
        let dma_ok: i32 = (sync_device.code == driver.driver_ok() &&
            driver.dma_buffer_is_mapped[u8](&buffer) == 0) as i32;
        driver.dma_buffer_release[u8](buffer);
        driver.dma_domain_release(domain);
        if (dma_ok == 0) { return 19; }
        let bad_domain: driver.DmaDomain = driver.dma_domain_new_emulated(0, 0, 99);
        let bad_buffer: driver.DmaBuffer[u8] = driver.dma_buffer_new_emulated[u8](
            0, 0, 99, 99);
        let bad_address: driver.BusAddress = driver.dma_buffer_map_emulated[u8](
            &bad_buffer, &bad_domain, 0x2000, 1);
        let bad_sync: driver.DriverStatus = driver.dma_buffer_sync_for_device[u8](&bad_buffer);
        let dma_rejected: i32 = (driver.dma_domain_is_valid(&bad_domain) == 0 &&
            driver.dma_buffer_is_valid[u8](&bad_buffer) == 0 &&
            driver.bus_address_is_valid(&bad_address) == 0 &&
            bad_sync.code == driver.driver_stale_handle()) as i32;
        // znc:allow A0102 -- @consumes BusAddress requires a standalone call.
        driver.dma_buffer_unmap[u8](&bad_buffer, bad_address);
        driver.dma_buffer_release[u8](bad_buffer);
        driver.dma_domain_release(bad_domain);
        if (dma_rejected == 0) { return 25; }
    }
    let object: kbuild.KernelObjectContract = kbuild.kernel_object_contract(
        driver.driver_target_x86_64(), linux.linux_kernel_6_6(),
        kbuild.object_format_et_rel(), 1, 1, 1, 1, 1, 1, 1,
        kbuild.kbuild_owner_kernel_final_link(), 0, 1);
    if (kbuild.kernel_object_contract_valid(object) == 0) { return 16; }
    return 0;
}
EOF
  if (cd "$tmp/positive" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/positive.log" 2>&1 && [ -x "$tmp/positive/out" ]; then
    set +e
    "$tmp/positive/out"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "  XX  shared driver core runtime (exit=$rc)"
      sed -n '1,80p' "$tmp/positive.log"
      exit 1
    fi
    echo '  ok  one pure-Zag core imports driver, emulator, and Linux metadata contracts'
  else
    echo '  XX  shared driver core did not compile'
    sed -n '1,120p' "$tmp/positive.log"
    exit 1
  fi
}

expect_reject() {
  name=$1
  source=$2
  make_case "$name"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  if (cd "$tmp/$name" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/$name.log" 2>&1; then
    echo "  XX  $name was accepted"
    exit 1
  fi
  if [ -e "$tmp/$name/out" ]; then
    echo "  XX  $name emitted an artifact after rejection"
    exit 1
  fi
  echo "  ok  $name rejected"
}

compile_positive
expect_reject forged_declaration '@resource @driver_handle(Forged) struct Forged { token: @owned(_zag_free) *opaque } fn main() i32 { return 0; }'
expect_reject forged_literal '@import("std:driver") as driver fn bad() driver.Device { return driver.Device{ .token = null as *opaque, .identity = 1, .adapter = 0 }; } fn main() i32 { return 0; }'
expect_reject field_escape '@import("std:driver") as driver fn bad(device: driver.Device) i64 { return device.identity; } fn main() i32 { return 0; }'
expect_reject pointer_cast '@import("std:driver") as driver fn bad(device: driver.Device) *i8 { return device as *i8; } fn main() i32 { return 0; }'
expect_reject handle_copy '@import("std:driver") as driver fn bad(device: driver.Device) driver.Device { let copy: driver.Device = device; return copy; } fn main() i32 { return 0; }'
expect_reject raw_driver_access '@import("std:driver") as driver fn bad(device: driver.Device) i32 @driver_control { unsafe { let p: *i8 = _zag_malloc(1); return p.* as i32; } return 0; } fn main() i32 { return 0; }'
expect_reject mmio_width '@import("std:driver") as driver fn bad(reg: @borrows *driver.MmioRegister[u16]) driver.MmioRead8 { return driver.mmio_read8(reg); } fn main() i32 { return 0; }'
expect_reject invalid_bitfield '@import("std:driver") as driver fn bad() driver.RegisterField { return driver.register_field_new(driver.mmio_width_32(), 31, 2, driver.endian_little()); } fn main() i32 { return 0; }'
expect_reject invalid_descriptor_field '@import("std:driver") as driver fn bad() driver.DescriptorField { return driver.descriptor_field_new(8, 3, driver.mmio_width_32(), driver.endian_little()); } fn main() i32 { return 0; }'
expect_reject atomic_width '@import("std:driver") as driver fn bad(atomic: @borrows *driver.Atomic[u16]) driver.AtomicRead8 { return driver.atomic_load8(atomic, driver.order_relaxed()); } fn main() i32 { return 0; }'
expect_reject atomic_non_atomic '@import("std:driver") as driver fn bad(value: @borrows *u32) driver.AtomicRead32 { return driver.atomic_load32(value, driver.order_relaxed()); } fn main() i32 { return 0; }'
expect_reject atomic_order '@import("std:driver") as driver fn bad(atomic: @borrows *driver.Atomic[u8]) driver.AtomicRead8 { return driver.atomic_load8(atomic, driver.order_release()); } fn main() i32 { return 0; }'
expect_reject atomic_rmw_width '@import("std:driver") as driver fn bad(atomic: @borrows_mut *driver.Atomic[u16]) driver.AtomicRead32 { return driver.atomic_fetch_add32(atomic, 1, driver.order_relaxed()); } fn main() i32 { return 0; }'
expect_reject atomic_rmw_order '@import("std:driver") as driver fn bad(atomic: @borrows_mut *driver.Atomic[u8]) driver.AtomicRead8 { return driver.atomic_exchange8(atomic, 1, driver.order_release()); } fn main() i32 { return 0; }'
expect_reject atomic_cas_failure_order '@import("std:driver") as driver fn bad(atomic: @borrows_mut *driver.Atomic[u32]) driver.AtomicCompare32 { return driver.atomic_compare_exchange32(atomic, 1, 2, driver.order_acquire(), driver.order_release()); } fn main() i32 { return 0; }'
expect_reject unbounded_irq 'fn bad() i32 @irq { while (true) { return 0; } return 1; } fn main() i32 { return bad(); }'
expect_reject irq_unknown_call 'fn helper() i32 { return 0; } fn bad() i32 @irq { return helper(); } fn main() i32 { return bad(); }'
expect_reject irq_unsynchronized_pointer 'fn bad(shared: @borrows *i32) i32 @irq { return shared.*; } fn main() i32 { return 0; }'
expect_reject irq_unknown_ffi 'extern fn external_irq() i32; fn bad() i32 @irq { return external_irq(); } fn main() i32 { return bad(); }'
expect_reject blocking_irq '@import("std:driver") as driver fn bad(lock: @borrows_mut *driver.DriverMutex) i32 @irq { let status: driver.DriverStatus = driver.driver_mutex_lock(lock); return status.code; } fn main() i32 { return 0; }'
expect_reject realtime_blocking '@import("std:driver") as driver fn bad(lock: @borrows_mut *driver.DriverMutex) i32 @realtime { let status: driver.DriverStatus = driver.driver_mutex_lock(lock); return status.code; } fn main() i32 { return 0; }'
expect_reject blocking_profile 'fn bad() i32 @irq @blocking { return 0; } fn main() i32 { return bad(); }'
expect_reject dma_use_after_unmap '@import("std:driver") as driver fn bad() i32 { unsafe { let buffer: driver.DmaBuffer[u8] = driver.dma_buffer_new_emulated[u8](8, 64, driver.dma_to_device(), driver.dma_streaming()); let address: driver.BusAddress = driver.bus_address_new_emulated(1, 1); driver.dma_buffer_unmap(&buffer, address); let value: u64 = driver.bus_address_value(&address); return value as i32; } return 0; } fn main() i32 { return bad(); }'
expect_reject stale_irq_handle '@import("std:driver") as driver fn bad() i32 { unsafe { let irq: driver.IrqHandle = driver.irq_new_emulated(3, driver.irq_exclusive()); driver.irq_release(irq); let status: driver.DriverStatus = driver.irq_acknowledge(&irq); return status.code; } return 0; } fn main() i32 { return bad(); }'
expect_reject unsupported_linux_api '@linux_api(61,99,6,256,1) fn unsupported() i32 { return 0; } fn main() i32 { return unsupported(); }'
expect_reject realtime_allocation 'extern fn alloc_mem(n: i32) *i8 @cabi @alloc; fn bad() i32 @realtime { let p: *i8 = alloc_mem(1); return p == null; } fn main() i32 { return bad(); }'
expect_reject realtime_mmio '@import("std:driver") as driver fn bad(reg: @borrows_mut *driver.MmioRegister[u32]) i32 @realtime { let status: driver.DriverStatus = driver.mmio_write32(reg, 1); return status.code; } fn main() i32 { return 0; }'

echo 'driver contract: PASS'
