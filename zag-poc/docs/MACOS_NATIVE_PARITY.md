# macOS native-parity contract

Apple Silicon support is a native target, not a Linux compatibility layer.
Every supported language feature must preserve its user-visible contract across
Linux and macOS; only the operating-system adapter may differ.

| Area | Linux adapter | macOS-native parity requirement |
|---|---|---|
| Compiler output | ELF + Linux ABI | signed PIE Mach-O + Darwin ABI |
| Project watcher | inotify | Darwin `kqueue` vnode watch for the project root, with bounded polling only if native event setup fails; recursive subtree coverage remains tracked work |
| Persistent planner | systemd user unit | launchd LaunchAgent |
| Process/files/time | Linux syscalls | Darwin syscalls and Darwin process semantics |
| CPU controls | x86 feature probes | ARM capability-aware, fail-closed controls |
| Debug information | DWARF/ELF sections | Mach-O `__DWARF` segment with self-hosted DWARF metadata and an updated embedded signature |
| Dynamic linking | ELF dynamic loader | Mach-O load commands, native dyld bind streams, and ARM64 libSystem import stubs; custom dylib install-name mapping remains tracked work |
| Hot reload | Linux runtime mechanism | Darwin-safe code/data protection and cache invalidation |
| GPU/device work | DRM driver adapters | explicit Apple-Silicon Metal platform identity; native Metal compiler/queue/readback remains unavailable rather than falling back to DRM |

`zagd_macos_daemon.zag` uses a native `kqueue` vnode watch for its project
root and falls back to bounded polling only when Darwin event setup fails. It
is advisory and foreground-independent; recursive subtree event delivery still
remains required before it can claim full inotify parity.

The Mach-O writer now emits `LC_DYLD_INFO_ONLY` bind information and a
page-aligned `__LINKEDIT` region for libSystem imports. External calls lower to
ARM64 stubs that branch through dyld-filled writable pointers, verified by a
native `getpid` executable; this is a Darwin loader path, not an ELF bridge.

Unsupported hardware or operating-system capabilities must be rejected with a
specific diagnostic. They must never silently route through Linux numbers,
QEMU, an ELF artifact, or a partial emulation path.
