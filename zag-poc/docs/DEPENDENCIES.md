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

For a development checkout that wants a reproducible direct sibling edge, use
the explicit opt-in mode:

```ini
[deps]
toolkit = { path = "../toolkit", mode = "sibling", version = "^1.2.3" }
```

Sibling mode requires a canonical `zag.lock` beside the consuming manifest and
binds only the directly imported module's alias, root, path, and raw checksum.
The foreground compiler revalidates those bytes before cache reuse and fails
closed on missing, malformed, stale, or symlinked inputs. `znc package lock`
can create this direct lock entry but does not claim transitive sibling
locking, graph/version solving, revision pinning, registry transport, or
authenticity. `tests/run_package_sibling_lock.sh` is the focused native and
negative evidence for this bounded slice.

## Compiler-enforced locked vendor imports

Source stored beneath the consuming project can opt into the bounded offline
vendor mode:

```ini
[deps]
vector = { path = "vendor/vector", mode = "vendor", version = "~1.4.0" }
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

This is an artifact-granular reproducibility contract, not package authenticity
or a complete package manager. A declared exact/caret/tilde or bounded wildcard
(`*`, `M.*`, `M.m.*`) version requirement
is checked against the dependency root's own `zag.mod` before resolution, and
provably incompatible same-root exact requirements and disjoint caret/tilde
requirements fail closed.
`znc package lock` records discovered transitive
`.zag` imports and `#embed` assets beneath declared vendor roots, and
compilation requires every relative vendor edge and embedded asset to appear in
the lock. Zag has only bounded caret/tilde/wildcard range intersection; it has no general
range/revision solver or automatic fetch. `selfhost/package_signature.zag`
provides explicit detached Ed25519 verification for a canonical index, but
package signatures are consumed before selection only for an opted-in local
`mode = "registry"` dependency that supplies matching `public_key` and
`signature` paths; unsigned registry dependencies retain the metadata mode.
Locked
vendor/registry entry modules now use a retained descriptor-bound
`openat2(..., RESOLVE_NO_SYMLINKS)` read in addition to the bounded
`newfstatat(..., AT_SYMLINK_NOFOLLOW)` pre-read guard. Transitive relative
modules/resources use the same retained descriptor read, while unlocked local
imports retain normal filesystem semantics. A bounded
`mode = "registry"` may consume a reviewed local
`zag-registry-index-v1` file and choose the highest compatible entry; it is
network-free metadata, not a public registry or signature authority. The
checksum identifies raw bytes; it is not a cryptographic signature. Version control remains authoritative
for the reviewed source revision and upgrade history.

`selfhost/package_registry_transitive.zag` adds a separate, bounded graph
audit seam: explicit `from<TAB>to<TAB>requirement` edges are traversed with
cycle, missing-node, conflict, and fuel-limit diagnostics, and a deterministic
create-only graph-lock record can be emitted. A conventional `registry.lock`
sidecar is now consumed by the default registry resolver when present; the
selected version/source/raw bytes must match the graph entry before the module
is admitted. The record still does not inspect artifact imports or provide
revision solving or registry transport.
`package_registry_graph_lock_verify` now independently checks that record's
envelope checksum, canonical ordering, exact graph coverage, selected version,
source, and raw index checksum, rejecting truncation and appended bytes. This
is still a caller-owned verification seam; it does not promote the graph lock
to resolver authority.
`package_registry_graph_lock_authorized_select` is the explicit opt-in
foreground seam: it verifies that the requested package is in the graph and
that the pinned version, source, and raw checksum match before returning a
selection. `package_import_registry_graph_authorize` adds the corresponding
foreground admission check for an already-resolved registry import: it binds
the resolver's retained version/source/checksum tuple to the same verified
graph lock and marks the result `graph_authorized=1`. Forged, stale, malformed,
and non-registry results fail closed. The default resolver also discovers a
present conventional `registry.lock` from the nearest manifest toward the
project root, while an explicit `registry_lock` path remains authoritative for
non-conventional locations. The shared parser retains a canonical
nearest-manifest registry edge stream in `CompilationUnit` and validates a
discovered graph lock against the complete stream; incomplete ownership
metadata remains fail-closed.

Nested registry manifests cannot smuggle an independent graph lock into the
parser path. When a root uses the conventional graph-lock sidecar, nested
imports walk to that same root-owned envelope; a nearer ordinary, malformed,
or different nested graph lock is rejected with a focused diagnostic. An
explicit non-conventional root sidecar still requires nested manifests to name
the shared path. `tests/run_parser_registry_graph.sh` covers the fail-closed
nested-lock case, while `tests/run_package_registry_lock_resolve.sh` covers
default root and nested resolver admission.

Compiler-owned standard modules use `@import("std:name")`. Project and vendored
modules use explicit paths. Imports fail closed when a file is missing or a
module cycle is detected.

See `docs/LOCAL_PACKAGE_IMPORTS.md` for the exact path rules, canonical lock
format, bounds, provenance behavior, and executable evidence.
