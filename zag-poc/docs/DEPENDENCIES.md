# Dependencies without a registry

Zag does not currently have a public package registry or network dependency
resolver. The supported reproducible workflows are local-first: dependency
source is reviewed, checked into the consuming repository or an explicit
sibling checkout, and imported either by a direct relative path or a bounded
`pkg:` alias declared in the nearest `zag.mod`.

## Direct relative imports

Example layout:

```text
my-project/
  zag.mod
  src/main.zag
  deps/vector/vector.zag
```

`src/main.zag`:

```zag
@import("../deps/vector/vector.zag") as vector

fn main() i32 {
    return vector.answer() - 42;
}
```

Build it normally:

```sh
znc src/main.zag -o app --run
```

Direct relative imports and ordinary local `pkg:` aliases are unlocked. Record
their exact source revision in version control and review diffs when updating
them.

## Compiler-enforced locked vendor imports

Source stored beneath the consuming project can opt into the bounded offline
vendor mode:

```ini
[deps]
vector = { path = "vendor/vector", mode = "vendor" }
```

Import an explicit module through that alias:

```zag
@import("pkg:vector/src/vector.zag") as vector
```

Vendor mode requires a canonical `zag.lock` beside `zag.mod`:

```text
format=zag-local-lock-v1
entry=vector<TAB>vendor/vector<TAB>src/vector.zag<TAB>FIRST,SECOND,BYTES
```

The compiler requires sorted, unique alias/root/module entries and rechecks the
deterministic raw-byte checksum before compilation. The exact `zag.mod` and
`zag.lock` snapshots participate in semantic and machine-cache identity; stale,
missing, malformed, or checksum-mismatched locks fail before cache reuse.
Package resolution performs no environment search, command execution, socket,
registry request, or fetch.

This is a module-granular reproducibility contract, not package authenticity or
a complete package manager. Zag has no lock/update generator, version or
revision solver, package signatures, public registry protocol, automatic fetch,
requirement that every transitive source-relative import be locked, non-Zag
asset snapshotting, or symlink containment. The checksum identifies raw bytes;
it is not a cryptographic signature. Version control remains authoritative for
the reviewed source revision and upgrade history.

Compiler-owned standard modules use `@import("std:name")`. Project and vendored
modules use explicit paths. Imports fail closed when a file is missing or a
module cycle is detected.

See `docs/LOCAL_PACKAGE_IMPORTS.md` for the exact path rules, canonical lock
format, bounds, provenance behavior, and executable evidence.
