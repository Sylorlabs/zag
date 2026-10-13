# macOS ARM64 parity validation — 2026-09-09

This report records the native Apple Silicon qualification completed after the
working-tree snapshot recorded in
[MACOS_PARITY_VALIDATION_2026-09-08.md](MACOS_PARITY_VALIDATION_2026-09-08.md).
The older report remains valid for its recorded snapshot; this report covers
the later Darwin service additions and their fresh-source release run.

Host: physical Apple Silicon macOS (`Darwin:arm64`).

## Results

| Area | Result |
|---|---|
| Fresh compiler rebuild | Pass; repo-local source-qualified compiler reached a byte-identical stage-2/stage-3 signed Mach-O fixed point |
| Native macOS release gate | **Pass: 68, fail: 0** |
| Shared ARM64 corpus | Pass: 101, fail: 0 |
| Ownership parameter contracts | Pass: 45, fail: 0 |
| Aggregate ownership provenance | Pass: 20, fail: 0 |
| Native LSP | Pass: 17, fail: 0 |
| macOS ZagScript authority | Pass: 27, fail: 0; 94 signed artifacts, 94 unique |
| Network.framework TLS probe | Pass; TLS 1.3 options, native blocks, system frameworks |
| Network.framework TLS handshake | Pass; explicit trust anchor and hostname rejection |
| Network.framework TLS HTTP composition | Pass; TLS 1.3 `nw_connection` send/receive, exact HTTP response, trust and hostname negatives |
| macOS OS services | Pass; `clock_gettime`, `arc4random_buf`, `mach_continuous_time`, `clonefile` |
| Dynamic plugin lifecycle | Pass; Mach-O `.dylib`, `dlopen`, `dlsym`, call, `dlclose`, unload and negative cases |
| Darwin concurrency service | Pass; EVFILT_USER kqueue SPSC channel, pthread worker, bounded timeout and signed rebuild |
| Package/install roundtrip | Pass; native archive extraction, installed standard library, checksum, no Git dependency, no clobber |
| Documentation truth | Pass: 0 failures |
| Diff whitespace check | Pass; no errors |

The release gate also passed native Mach-O generation/linking/loading, ARM64 C
ABI and relocation cases, Metal device and shader execution, checked pointer
and allocator witnesses, filesystem and process adapters, IPv4/UDP/DNS/HTTP/
WebSocket protocol suites, SQLite, planner stress, hot reload, and package
layout.

## Native macOS additions

The qualified target now documents and tests these macOS-native capabilities:

- `mach_continuous_time` supplies a sleep-inclusive monotonic clock.
- `clonefile` supplies APFS copy-on-write filesystem cloning.
- Network.framework and Security.framework supply system TLS policy, trust
  evaluation, hostname verification, and asynchronous connection-managed I/O.
- Metal supplies Apple GPU device, queue, shader, and shared-memory execution.
- Mach-O/dyld supplies signed images, native dylibs, rebasing/binding, and the
  live text cache-synchronization path.
- kqueue supplies Darwin-native event notification for the bounded channel and
  recursive project watcher.

## Remaining target boundaries

The supported portable product surface has a validated macOS ARM64 equivalent.
Some Linux behavior remains inherently target-specific: ELF tooling and raw
Linux syscall-number interfaces, `/proc`, inotify, systemd, Linux kernel/driver
interfaces, DRM/render-node internals, qemu-user behavior, and the Linux
OpenSSL SONAME reference path. macOS uses Mach-O/dyld, kqueue, launchd-oriented
project services, Network.framework/Security.framework TLS, Metal, and Darwin
sockets for the corresponding user-facing roles.

The bounded networking surface remains IPv4-focused, and the project still does
not claim a general async/await scheduler, MPMC channel library, complete
whole-language memory safety, or universal database/GPU/API coverage on either
target.

## Qualification conclusion

macOS ARM64 parity is complete for the supported portable product surface
covered by the release contract. Linux retains native implementations for
Linux-specific kernel, loader, and system-service interfaces; those interfaces
do not create a user-facing macOS parity gap where the project defines a native
Darwin equivalent.
