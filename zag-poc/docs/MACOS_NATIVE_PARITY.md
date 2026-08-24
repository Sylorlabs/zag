# Apple Silicon macOS native support contract

This document refines the authoritative row in `docs/SUPPORT.md`. The
`macos-arm64` target is a scoped native development target, not a Linux
compatibility layer and not a claim of Linux AArch64 feature parity. A backend
implementation or one passing fixture does not broaden this boundary.

## Current scoped capability

| Area | Evidence-bearing path | Boundary |
|---|---|---|
| Native output | `znc source.zag --target macos-arm64 -o app` | signed PIE ARM64 Mach-O executable with Darwin `LC_MAIN`, `__TEXT`/`__DATA`, PIE-relative data addresses, and a deterministic embedded ad-hoc signature |
| v1 runtime slice | native runtime fixture on Apple Silicon | arguments, strings/data, heap, basic file I/O, bounded process execution, stdout, and exit status only as exercised by the native gate |
| Dyld imports | positive and negative import-bearing executable fixtures | `LC_DYLD_INFO_ONLY`, bind stream, and ARM64 stubs for an exact, compiler-validated libSystem/Metal/libobjc symbol-and-ABI allowlist; unknown names and mismatched declarations fail before output, and this is not a general linker |
| Debug information | standalone `--debug` executable fixture | self-hosted DWARF in a Mach-O `__DWARF` segment, with the resulting image signed; imports cannot be combined with this mode |
| CPU and v2 slices | explicit native fixtures | generic/Apple-Silicon baseline selection and bounded ARMv8 fence plus LL/SC atomic witnesses; these do not establish edition-2027 target support |
| Project planner | optional `zagd_macos_daemon.zag` fixture | Darwin `kqueue`/polling adapter and launchd helper are advisory; planner availability never changes foreground compiler correctness or proves inotify parity |

The native claim-producing gate is
`tests/run_macos_arm64_release.sh`. It must run on physical Apple Silicon with a
matching macOS compiler seed. A seed is eligible for a release only after the
gate reaches its byte-identical second/third self-host generations and all
runtime and negative witnesses pass. Merely producing a Mach-O compiler, or
cross-emitting an artifact on Linux, is development evidence rather than a
release claim.

## Explicitly unsupported

The current target must fail closed for all of these requests:

- Mach-O object (`.o`), archive (`.a`), and shared-library (`.dylib`) output;
  `--emit-obj` and `--emit-static` may not substitute an executable.
- BSS-backed edition-2027 globals or any feature that requires a supported
  Mach-O BSS/global-storage layout. An emitted `__DATA` image is not BSS proof.
- edition-2027 checked raw-pointer safety and memory sanitizing through
  `--safety=checked` or `--sanitize=memory`. The isolated atomic witnesses do
  not broaden this boundary.
- `--debug` combined with dyld imports.
- general external linking through `-l`, `-L`, `zag.mod` library declarations,
  arbitrary dylib install names, or shared-library production. The closed
  import-bearing executable path is the only dyld slice.
- Linux hot-reload, Linux driver, inotify, `/proc`, systemd, ELF, or qemu-user
  behavior presented as a macOS-native implementation.

`--dynamic` is retained for import-bearing executable fixtures. On
`macos-arm64` it does **not** mean shared-library output and does not establish
parity with either Linux ELF dynamic mode or a system linker.

## Raw syscall namespace

`_zag_raw_syscall` is a legacy source boundary whose numbers are Linux x86-64
syscall identities on every backend. For Mach-O, the compiler recognizes only
an audited literal adapter subset (read, close, mkdir (Linux 83 to Darwin 136),
getpid, fcntl, dup2, timeout, fork, execve, wait4, kill, setpgid, and pipe). It
translates those calls and their required argument/return differences to Darwin
behavior.

The `fcntl` entry admits only the literal `F_SETFL` plus Linux `O_NONBLOCK`
tuple used by the bounded process adapter. Other command/argument tuples return
`ENOSYS`; Linux and Darwin command numbers must never alias by accident.
Syscall identities must be non-negative literals within the signed 32-bit
range, so narrowing cannot wrap a large value into an audited operation.

An unknown Linux number or a computed raw syscall number returns Darwin
`ENOSYS` (78) without issuing an unrelated trap. Native macOS implementation
code may use the separate `_zag_darwin_syscall` boundary, which itself requires
a non-negative integer literal. Neither escape hatch is a portable public
syscall API, and Linux syscall coverage must never be inferred for macOS.

Unsupported hardware or operating-system capabilities must reject with a
specific diagnostic and leave no substitute artifact. They must never silently
route through Linux numbers, qemu, an ELF image, or a partial emulation path.
