# Zag Compiler — Agent Working Rules

## Platform Support

User-facing claims must match [`docs/SUPPORT.md`](docs/SUPPORT.md). Backend code
or a focused test never broadens that contract by itself.

### x86-64 Linux (primary)
The primary target. All syscalls use Linux x86-64 numbers directly.
Supports static, dynamic (`--dynamic`), and object (`--emit-obj`) output modes.

### AArch64 Linux (supported scoped target)
ARM64 is supported for the exact static, object, dynamic, safety, qemu-user,
and native-CI rows below. This is not a claim that every x86-64 v2 feature has
ARM64 parity. The ARM64 codegen
(`acodegen.zag`) translates x86-64 syscall numbers to ARM64 asm-generic
syscall numbers at compile time via `ac_emit_syscall_xlate`. This is a
compare-and-remap sequence emitted before each `svc #0` instruction.

**Syscall translation**: Zag source code uses x86-64 syscall numbers
everywhere. The ARM64 backend translates them to asm-generic numbers:
- 33 simple number remaps (e.g., read 0→63, write 1→64, exit 60→93)
- 7 arg-rearrangement cases where x86-64 syscalls don't exist on ARM64:
  - `open` → `openat(AT_FDCWD, ...)` (2→56)
  - `dup2` → `dup3(..., 0)` (33→24)
  - `fork` → `clone(SIGCHLD, 0, ...)` (57→220)
  - `rename` → `renameat(AT_FDCWD, ..., AT_FDCWD, ...)` (82→38)
  - `mkdir` → `mkdirat(AT_FDCWD, ...)` (83→34)
  - `rmdir` → `unlinkat(AT_FDCWD, ..., AT_REMOVEDIR)` (84→35)
  - `unlink` → `unlinkat(AT_FDCWD, ..., 0)` (87→35)
- Unknown syscall numbers pass through unchanged (return -ENOSYS on ARM64)

**ELF entry point**: `AHDRS2 = 232` in `elf_arm64.zag` (64-byte ELF header
+ 3×56-byte program headers). Was incorrectly 176 (2 program headers)
which caused the entry point to land inside the program header table.

**BSS segment p_offset**: The BSS LOAD segment uses a page-aligned
`p_offset` (not 0) to satisfy `p_offset ≡ p_vaddr (mod PAGE_SIZE)` under
kernels with 4K/16K/64K pages. The BSS has no file content (`p_filesz=0`).

**Output modes** (edition-2027 only for object/dynamic):
- **Static** (default): `znc --target arm64 source.zag -o out` — produces
  a static ELF64 executable via `write_elf_arm64_data`.
- **Object**: `znc --target arm64 --emit-obj source.zag -o out.o` — produces
  ET_REL with `.text`, `.rela.text`, `.symtab`, `.strtab`, `.shstrtab`.
  Requires `@cabi_export` pub fns and `@cabi` externs. Relocations use
  `R_AARCH64_CALL26 = 283` (BL instruction, addend=0). Emitted by
  `write_elf_arm64_object_reloc` in `elf_arm64.zag`.
- **Dynamic**: `znc --target arm64 --dynamic --needed libNAME.so.N source.zag`
  — produces a dynamic executable with PT_INTERP (`/lib/ld-linux-aarch64.so.1`),
  GOT at `0x9000000`, and `R_AARCH64_GLOB_DAT = 1025` relocations. Emitted
  by `write_elf_dynamic_arm64` in `elf_dynamic_arm64.zag`.

**Safety checks** (`--safety=checked` / `--sanitize=memory`):
- `ac_emit_checked_raw_access` emits null, alignment, use-after-free, and
  out-of-bounds probes before raw pointer dereferences.
- `ac_emit_alloc_access_acquire` / `ac_emit_alloc_access_release` register
  and retire allocations in a provenance registry at `BSS_VBASE + 66560`
  (capacity 3072 entries, 16 bytes each).
- `ac_emit_raw_index_address` emits overflow-checked index arithmetic.
- Panics use `ac_emit_panic` (write to stderr + exit(1) via ARM64 syscalls).
- These mirror the x86 backend's `cg_emit_*` safety functions.

**GOT/dynamic calls**: In dynamic/object mode, extern calls go through
`ac_dynamic_index` to find the GOT slot. Object mode emits `ai_call_ext`
(relocation); dynamic mode loads the GOT slot and calls indirectly.

**QEMU user-mode testing**: Use `qemu-aarch64-static` to run ARM64 binaries.
Note: QEMU's aarch64 target defines `TARGET_O_DIRECTORY = 0o40000 = 16384`,
which differs from the asm-generic kernel value (`0o200000 = 65536`). This
is a QEMU user-mode quirk that does NOT affect real ARM64 hardware. Opening
directories with `O_RDONLY` (without `O_DIRECTORY`) works under QEMU and
on real hardware.

### i686 Linux (limited milestone)
The i386 backend (`i386_codegen.zag`) is a limited milestone target.
Supports `--emit-obj` and `--emit-static` (archive) output.

## Bootstrap

After modifying the compiler source, run:
```
ZAG_BOOTSTRAP_MEMORY_GUARD=off bash bootstrap.sh
```
The bootstrap must reach a byte-identical fixpoint. The `ZAG_BOOTSTRAP_MEMORY_GUARD=off`
env var disables the systemd memory guard which can interfere with the
bootstrap process.

## Cache System

The `.zag-cache/` directory is flat — no nested subdirectories within
`zagd/` or `foreground/`. The `znc clean-cache [path]` command purges
the cache and stops the daemon. Cache versioning uses `.cache-version`
files to detect stale caches.

## Bloat + Agent-Bug Lints (analyze.zag)

The analyzer (`selfhost/analyze.zag`) includes two lint families beyond the
existing leak (L0xxx) and efficiency (E0xxx) checks:

### B0xxx — Bloat Lints
Dead code, redundant patterns, and verbose constructs.

| Code | Default | Description |
|------|---------|-------------|
| B0101 | on | Unreachable code after return/break/continue |
| B0103 | on | Unused local variable (never read) |
| B0104 | on | Assignment overwritten before read |
| B0105 | on | Verbose boolean return (`if c { return true; } else { return false; }`) |
| B0107 | on | Double negation (`!!x`) |
| B0108 | on | Negated comparison (`!(a == b)` → `a != b`) |
| B0109 | on | Redundant boolean literal (`x == true`) |
| B0110 | on | Tautological self-comparison (`x == x`) |
| B0113 | on | if/else with identical bodies |
| B0102 | pedantic | Dead branch (condition always true/false) |
| B0111 | pedantic | Empty block (empty if/else/while body) |
| B0112 | pedantic | Duplicated adjacent statements |
| B0114 | pedantic | Duplicated switch arm bodies |
| B0115 | pedantic | Function complexity exceeds threshold |

### A0xxx — Agent-Bug Lints
Common mistakes that lead to incorrect runtime behavior.

| Code | Default | Description |
|------|---------|-------------|
| A0101 | on | Off-by-one loop bound (`i <= N` with indexing) |
| A0102 | on | Ignored must-use return value |
| A0103 | on | Bitwise-for-logical operator on booleans (`&` vs `&&`) |
| A0105 | on | Self-assignment (`x = x`) |
| A0106 | on | Dead computation (expression result discarded) |
| A0107 | on | Dead loop (condition/increment direction mismatch) |
| A0108 | on | Duplicate condition across consecutive ifs |
| A0109 | on | Division/modulo by 0 or modulo by 1 |
| A0110 | pedantic | Shift by constant >= 32 |
| A0112 | pedantic | Symmetric-condition duplicate (`a < b` then `b > a`) |

### Flags
- `--analyze-bloat=off` — disable all B0xxx lints
- `--analyze-agent=off` — disable all A0xxx lints
- `--analyze-complexity=N` — set B0115 threshold (default 15)
- `--analyze-strict` — treat warnings as errors
- `--analyze-pedantic` — enable pedantic-tier lints
- `--no-analyze` — silence all analyzer warnings

### Suppression
- `// znc:allow CODE` — suppress a lint on the current line
- `// znc:allow-file CODE` — suppress a lint for the entire file
- Multiple codes can be listed: `// znc:allow B0101 B0103`

### Test Gate
Run `bash tests/run_native_lint.sh` to verify all lints fire correctly.
Example files: `examples/lint_bloat.zag`, `examples/lint_agent.zag`,
`examples/lint_suppression.zag`.

## Edition-2027 v2 @cabi

The `@cabi` / `@cabi_export` annotations gate the v2 C ABI contract.
- Edition is determined by `v2_project_edition(path)` (returns `"2027"` or `""`).
- `znc_dynamic_extern_syms` collects extern symbols: non-`_zag_` externs
  in edition-2027 must be annotated `@cabi`.
- `znc_object_externs_ok` validates that all externs in object mode are `@cabi`.
- `znc_x86_object_exports` collects `@cabi_export` pub fns for object output.

## Key Files

- `selfhost/native/acodegen.zag` — ARM64 codegen: syscall translation,
  safety checks, dynamic/object mode calls, alloc provenance probes
- `selfhost/native/ncodegen.zag` — x86-64 codegen (defines `BSS_VBASE`)
- `selfhost/native/elf_arm64.zag` — ARM64 static ELF writer + ET_REL
  object writer (`write_elf_arm64_object_reloc`)
- `selfhost/native/elf_dynamic_arm64.zag` — ARM64 dynamic ELF writer
  (`write_elf_dynamic_arm64`, GOT, PT_INTERP, R_AARCH64_GLOB_DAT)
- `selfhost/native/aarch64.zag` — ARM64 instruction encoder +
  `aencode_with_labels` (returns `AEncoded` with relocs for object mode)
- `selfhost/native/aisa.zag` — ARM64 ISA definitions (`A_DATA_VBASE`,
  `ai_call_ext`, register constants)
- `selfhost/native/znc.zag` — CLI driver: `build_arm64` dispatches
  static/object/dynamic modes; runs on x86-64
- `selfhost/analyze.zag` — static analyzer: leak (L0xxx), efficiency
  (E0xxx), bloat (B0xxx), and agent-bug (A0xxx) lints
- `selfhost/v2_edition.zag` — edition-gated v2 syntax rejection
