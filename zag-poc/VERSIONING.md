# Zag Versioning Policy

## Version Scheme

Zag uses **CalVer**: `YYYY.MM.PATCH`

```
2026.06.0
^^^^  ^^ ^
year  |  patch within the month (0-based)
      month
```

**Rationale.** Zag's v1 language core is frozen while the implementation is
still evolving rapidly. Tying releases to the calendar makes the temporal distance
between two releases immediately legible without consulting a changelog. SemVer's
MAJOR signal is replaced by the **edition** mechanism (see below). Within a
single `YYYY.MM` series, PATCH increments are backwards-compatible bug fixes and
additive-only changes; the patch counter resets to 0 at the start of each month.

The current development version string is `2026.06.0-dev`. The `-dev` suffix is
stripped for tagged releases.

## Compatibility Tiers

Four distinct tiers govern what "compatible" means. Each has its own stability
promise.

### 1. Language Tier (syntax + semantics)

The grammar of Zag source code and the meaning of every syntactic construct,
including effects (`@realtime`, `@noalloc`, `@pure`, `@total`), operator
contracts, structural interfaces, and module imports.

**Current status: frozen v1 core.**

Breaking changes to the supported core require a new **edition** (see Editions
below). Experimental features outside `docs/V1_LANGUAGE_SPEC.md` carry no
compatibility promise. Code that compiles under edition `2026`
will continue to compile forever under a compiler that supports that edition.

### 2. ABI Tier (struct layout, calling convention, ELF symbol names)

The binary interface between separately compiled Zag translation units and the
host OS: struct field layout, the calling convention used for function calls, and
the mangled names of exported ELF symbols.

**Current status: explicitly unstable.**

The v1 language freeze does not freeze the binary ABI. Recompile everything
against a new toolchain release until an ABI edition is declared. Current layout
and calling rules are documented in `COMPATIBILITY.md`.

### 3. Compiler CLI Tier (`znc` flags)

The command-line interface of `znc`, the native compiler and only supported
production build path.

**Current status:** After `2026.06.0`, all flag additions to `znc` are
**additive-only**. Flags documented in that release will not be renamed or
removed within edition `2026`. New flags may be added in any release.

`zagc` is a **differential-testing oracle** (the legacy C-emitting compiler).
Its CLI carries **no stability guarantees** and it is not a supported build path.

### 4. Stdlib Tier (`std/` module interfaces)

The public API of modules under `std/` (`list`, `map`, `rt`, `sort`, `hashmap`,
`strbuf`, etc.).

**Current status:** After `2026.06.0`, the public API of existing `std/` modules
is **additive-only**. Existing exported function signatures will not change.
New functions may be added to existing modules in any release.

## Editions

The `edition` field in `zag.mod` pins the language version a source tree was
written against:

```
name    = "my_project"
version = "1.0.0"
edition = "2026"
```

A compiler that supports edition `2026` must compile all valid edition-`2026`
source forever, even after language changes in later editions. When the compiler
makes a breaking language change, it introduces a new edition string (e.g.,
`"2027"`). Code without an edition field defaults to the oldest supported
edition.

The compiler itself is declared with `edition = "2026"` in its own `zag.mod`.

## Deprecation Policy

1. A feature is marked deprecated in a release with a note in `CHANGELOG.md`.
2. The compiler emits a diagnostic on use when `-Wdeprecated` is passed. No
   warning is not emitted by default in edition `2026`.
3. The feature is **eligible for removal** after **two releases** (two calendar
   months) have passed. Removal happens at most one release after that window.
4. `-Werror-deprecated` promotes deprecation diagnostics to errors — useful for
   automated migration gating in CI.

The two-release rule applies from the first `2026.06.x` release onward.

## Minimum Supported Platform

| Platform        | Status          | Notes                                           |
|-----------------|-----------------|-------------------------------------------------|
| x86-64 Linux    | **Supported**   | Only current target; native ELF, no libc        |
| ARM64 Linux     | Planned         | Requires AArch64 ISA + ELF backend             |
| RISC-V Linux    | Planned         | Requires RV64GC ISA + ELF backend              |
| macOS (any)     | Not planned yet | Requires Mach-O backend                         |
| Windows         | Not planned     | Requires PE/COFF backend                        |

The ABI used is Linux syscall (`SYS_write`, `SYS_read`, `SYS_mmap`, `SYS_exit`,
etc.). Generated binaries have no dynamic loader dependency and no libc
dependency. The runtime uses basic Linux I/O, memory, process, and monotonic
clock syscalls directly.

## v1 Commitments

The language tier is normative; ABI and compiler internals remain explicitly
unstable. The two hard commitments are:

1. `edition = "2026"` sources will be accepted by the entire `2026.06.x` series.
2. The `znc` binary produced by `bootstrap.sh` will reproduce itself
   byte-identically (the self-hosting fixpoint guarantee verified by
   `tests/check_native_bootstrap_repro.sh`).
