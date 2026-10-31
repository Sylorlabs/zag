# Declared local package imports

Zag supports a bounded local package alias for sibling or vendored source. This
is a source-resolution contract, not a package registry.

Declare the dependency in the consuming project's nearest `zag.mod`. Relative
paths are interpreted from that manifest, not from the compiler's working
directory:

```ini
name = "prismstudio"
version = "0"
edition = "2026"

[deps]
zagkit = { path = "../zagkit", version = "^1.2.0" }
```

Import an explicit Zag module beneath that declared root:

```zag
@import("pkg:zagkit/src/zagkit.zag") as zagkit
```

Build normally, from the project or with an absolute source path:

```sh
znc src/main.zag -o app
```

The resolver starts at the importing file's directory and selects the nearest
ancestor `zag.mod`. It then:

1. finds exactly one matching key in `[deps]`;
2. resolves its `path` relative to that manifest;
3. when present, checks the dependency root's own top-level `version` against
   an exact, `^`, or `~` major.minor.patch requirement;
4. appends the explicit module path from the `pkg:` import; and
5. requires the resulting `.zag` file to exist before parsing it.

Modules inside the dependency keep using ordinary source-relative imports.
Their own `pkg:` imports resolve from their nearest manifest, which provides a
foundation for explicitly declared local dependency graphs without a global
search path.

Resolution fails closed for missing manifests, undeclared or duplicate aliases,
missing modules, a missing or unparseable `path` in the matching dependency
entry, and module paths containing `.` or `..` segments. Dependency roots must
be bounded relative paths using `/`; absolute, home-expanded, backslash, colon,
URL, and scp-like forms are rejected. Parent segments remain valid in dependency
roots so sibling declarations such as `../zagkit` work. Package names and module
paths are bounded, and module paths must name a `.zag` file. The manifest reader
validates the relevant local-dependency subset; it is not a general TOML
validator for unrelated project metadata.

Selection is independent of the compiler's working directory: absolute and
project-relative entry paths select the same nearest manifest and dependency.
The integration gate compiles both forms and requires byte-identical native
artifacts.

## Opt-in direct sibling lock

Development checkouts can opt a single parent-relative sibling root into the
same deterministic raw-byte lock protocol without claiming a complete package
graph:

```ini
[deps]
toolkit = { path = "../toolkit", mode = "sibling", version = "^1.2.3" }
```

`mode = "sibling"` requires `zag.lock` beside the consuming `zag.mod`, with a
direct entry matching the alias, exact declared root, and explicit imported
module:

```text
format=zag-local-lock-v1
entry=toolkit<TAB>../toolkit<TAB>src/toolkit.zag<TAB>FIRST,SECOND,BYTES
```

This bounded mode permits exactly one `../<safe-name>` root and locks only the
direct imported module. It does not lock transitive relative imports or assets,
and it does not turn ordinary unlocked sibling imports into locked ones. The
foreground compiler rechecks the retained module bytes before cache reuse,
rejecting missing, malformed, stale, or symlinked inputs; it also checks the
declared sibling version requirement. `znc package lock` is create-only for
this explicit direct entry. `tests/run_package_sibling_lock.sh` proves native
execution, absolute/relative invocation and checkout relocation determinism,
generator output, missing/stale/malformed-lock rejection, symlink rejection,
cache revalidation, and a zero-network trace when tracing is available. This
is a reproducibility slice, not transitive dependency solving, revision
pinning, a public registry, or package authenticity.

This resolver is not a general filesystem containment sandbox. Declared
unlocked dependency roots may use parent segments, and filesystem symlinks are
followed normally. Locked sibling/vendor/registry inputs take the stricter path: every
existing component is checked without following symlinks and a symlink fails
closed. Projects must still review unlocked declared paths and links to ensure
they remain within the workspace boundaries the project intends.

## Locked vendored mode

A dependency stored beneath the consuming project can opt into compiler-enforced
offline locking:

```ini
[deps]
zagkit = { path = "vendor/zagkit", mode = "vendor" }
```

Vendor entries may carry the same bounded requirement:

```ini
zagkit = { path = "vendor/zagkit", mode = "vendor", version = "~1.4.0" }
```

The resolver accepts only canonical `major.minor.patch`, `^major.minor.patch`,
or `~major.minor.patch` requirements. The dependency's own `zag.mod` must
publish a canonical three-part version when a requirement is present. Exact
requires equality; `^` permits compatible releases below the next major (or
the next minor/patch for zero-major versions); `~` permits releases below the
next minor. This is local compatibility checking, not a registry or revision
solver.

When two aliases in one manifest use the same declared root, the resolver
rejects provably incompatible exact requirements and disjoint caret/tilde
intervals before loading either module. It deliberately does not claim
multi-version graph solving; that requires a package graph/version authority.

Vendor mode requires `zag.lock` beside that `zag.mod`. Its first version is a
small, canonical, artifact-granular format. The separators on `entry=` lines are
literal tabs and the file ends in one LF:

```text
format=zag-local-lock-v1
entry=zagkit<TAB>vendor/zagkit<TAB>src/zagkit.zag<TAB>FIRST,SECOND,BYTES
```

Create the first lock from the explicit package graph with the foreground
compiler:

```sh
znc package lock src/main.zag
```

The generator is create-only and refuses to replace an existing lock. It scans
all explicit `pkg:` imports reached from the source, then adds every discovered
relative `.zag` import and `#embed` asset below those vendor roots. Each
matching dependency must use `mode = "vendor"`; the generator reads exact raw
bytes and emits the canonical sorted entries below the
`format=zag-local-lock-v1` header. Use `--output` to choose a new destination.
It checks the declared version requirement before collecting bytes, but does
not solve competing versions or contact a registry; those remain outside this
bounded generator contract.

Entries are strictly bytewise sorted by alias, root, then module. Blank,
duplicate, reordered, unknown-record, unknown-alias, malformed, noncanonical
decimal, and root-mismatch entries fail closed. A canonical comment line starts
with exactly `# `, contains only printable ASCII after that prefix, and is
ignored for entry ordering while remaining part of the lock's raw provenance
identity. Every entry must name exactly one `mode = "vendor"` dependency, use
that dependency's exact declared root, name an existing traversal-free source
module or embedded asset, and checksum at most 8 MiB of raw bytes. A lock is bounded to 256
entries and 64 MiB of checked raw bytes in total. The imported `pkg:`
alias/root/module tuple must have exactly one entry. All entries are rechecked
on every foreground compilation, including entries for additional
source-relative modules that a project elects to pin.

The raw checksum is deliberately reproducible without target overflow rules and
is not a signature. Starting with `first = 216613626` and
`second = 131542391`, update once per byte `b`:

```text
first  = (first  * 257 + b + 1) mod 1000000007
second = (second * 263 + b + 1) mod 1000000009
```

`BYTES` is the exact raw length. Each field is unsigned canonical decimal (zero
is `0`; other values have no leading zero). For example, a portable local
calculation is:

```sh
od -An -tu1 -v vendor/zagkit/src/zagkit.zag |
awk 'BEGIN{a=216613626;b=131542391;n=0}
{for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;b=(b*263+$i+1)%1000000009;n++}}
END{printf "%.0f,%.0f,%d\n",a,b,n}'
```

The resolver reads each successful import's `zag.mod` once and, in vendor mode,
its `zag.lock` once. Those exact buffers remain owned by the resolution until
the parser transfers them into the compilation unit. Multiple `pkg:` imports
through the same file deduplicate only when their snapshots are byte-identical;
a differing same-path snapshot fails instead of silently selecting one. The
resolver checks the on-disk module bytes while resolving, and the parser checks
the selected checksum again against the exact source slice retained for
compilation. Vendor roots have the exact traversal-free shape `vendor/<name>`
(nested safe segments are allowed). No environment lookup, command execution,
socket, registry request, or fetch path exists in package resolution, which
consumes the checked-in manifest, lock, and explicit vendored module bytes.
Like every compilation, the surrounding compiler still consumes its own
executable/runtime inputs and the explicitly named root source.

Parsing and package validation complete before any foreground machine-cache
lookup. A missing, malformed, or checksum-stale lock therefore rejects the
compile even when the same source previously populated a valid machine-code
cache entry. Exact manifest and lock snapshots are `CompilationUnit.resources`,
not source modules. The foreground cache hashes their path and raw bytes, and
the advisory semantic manifest emits checksum-bound `dependency_input_node`
records whose raw hashes participate in graph/artifact identity. A comment-only
manifest or canonical lock-comment change therefore forces a cache miss and a
new semantic identity while deterministic compilation may still emit the same
native bytes.

`zagd` revalidates dependency-input and module-node bytes before accepting a
semantic record. Foreground publication keeps the selected root module
project-relative, projects every other in-project module/resource to a
canonical project-relative path, and uses a canonical absolute path only for an
external input. Invocation from the project or its parent therefore produces
the same record, and a self-contained vendored project retains the same
semantic/cache graph identity at an unrelated checkout path. The daemon seeds
in-project manifest/lock inputs into its project snapshot and observes
in-project `zag.mod`/`zag.lock` events. Safe canonical external package/module
nodes are revalidated directly but are not persisted in the project-relative
watcher index; their graph names intentionally remain location-bound, and
external sibling changes still rely on the next foreground compile or semantic
revalidation. This daemon limitation cannot bypass foreground package
enforcement.

Locked vendor and registry paths reject symlink components before reading the
index, lockfile, module, relative import, or embedded resource. The manifest,
index/lock, and selected package-entry module are opened with Linux
`openat2(..., RESOLVE_NO_SYMLINKS)` and the exact entry bytes are retained into
the parser; transitive relative modules and embedded resources use the same
retained no-symlink read. Ordinary local
dependencies without `mode = "vendor"` or `mode = "registry"` retain the
sibling-path behavior above and do not implicitly become locked.

## Canonical offline registry-index protocol

The package layer also ships a strict local index/query codec for projects that
want a reviewed registry-shaped input without enabling network access. Its
record is deliberately explicit about its trust boundary:

```text
format=zag-registry-index-v1
authority=local-file-v1
signature=none
entry=toolkit<TAB>1.4.0<TAB>src/toolkit.zag<TAB>FIRST,SECOND,BYTES
checksum=FIRST,SECOND,BYTES
```

`tests/run_package_registry.sh` proves the executable codec and a transitive
two-index foreground build. It requires
traversal-free source paths, canonical SemVer, strictly increasing
name/version order, unique records, a bounded 256-entry index, an outer raw-byte
checksum, and deterministic exact/caret/tilde highest-compatible selection.
Each entry source path is resolved relative to the directory containing that
index, so moving a complete reviewed registry subtree preserves its graph
identity without depending on the importing project's current directory.
Unknown fields, forged signature labels, reordered entries, appended bytes,
malformed requirements, and missing compatible versions fail closed. The
selected source bytes are retained from the checked descriptor before parsing;
the index remains metadata-only and is not a signature authority.

This protocol is offline and metadata-only. A dependency may opt into it with
`mode = "registry"` and a local index path:

```ini
[deps]
toolkit = { path = "registry/index.zag", mode = "registry", version = "^1.0.0", public_key = "registry/public.pem", signature = "registry/index.sig" }
```

The foreground resolver selects the highest compatible entry, opens the
selected source under the no-symlink descriptor policy, and compares its raw
tuple before parsing the retained bytes. A selected module
may use a nearest `zag.mod` to import another local registry index; the gate
compiles that two-level graph and requires native execution. It does not fetch,
speak HTTP, or solve competing registry graphs. When both optional signature
paths are present, the resolver verifies the detached Ed25519 signature before
selecting an entry; missing, malformed, mutated, or symlinked signed inputs
fail closed;
the selected index source must also equal the explicit module path in the
`pkg:` import; mismatches fail closed. Every component of a locked
registry/vendor index, module, lockfile, relative module, or embedded resource
is checked with Linux `newfstatat(..., AT_SYMLINK_NOFOLLOW)` before bytes are
read; an observed symlink fails closed. The complete locked package graph is
now read through retained no-symlink descriptors on the Linux x86-64 resolver
host; the broader trust and transport features remain outside the current
package authority.

## Registry-resolution lock pin (explicit opt-in)

The compiler also ships a small `zag-registry-lock-v1` codec for validating a
reviewed selection record that the current resolver integration consumes. Its
canonical entry shape is:

```text
format=zag-registry-lock-v1
entry=toolkit<TAB>registry/index.zag<TAB>INDEX_FIRST,INDEX_SECOND,INDEX_BYTES<TAB>1.4.0<TAB>src/toolkit.zag<TAB>ARTIFACT_FIRST,ARTIFACT_SECOND,ARTIFACT_BYTES
checksum=FIRST,SECOND,BYTES
```

`tests/run_package_registry_lock.sh` proves 18/18 validation cases for the
dependency-neutral lock codec, including canonical ordering, duplicate and
truncation rejection, selected version/source checks, and stale
index/artifact-byte rejection. The codec itself remains filesystem-neutral:
it performs no registry lookup, network fetch, Git operation, or lock
generation. The resolver consumes it when a registry dependency explicitly
declares `registry_lock = "relative/path.lock"` or when a conventional
`registry.lock` is present in the nearest manifest chain; it reads that
lockfile with no-follow bounded I/O and rejects any selected index path,
version, source, raw checksum, or artifact-signature path mismatch before the
module enters the parse graph. `tests/run_package_registry_lock_resolve.sh`
proves this foreground path 18/18, including version/signature mutations and
nested default-sidecar discovery. A nested registry manifest may explicitly point at the shared
sidecar with a bounded parent-relative spelling such as
`registry_lock = "../registry.lock"`; the v2 scope records the manifest
directory so identical aliases and relative index paths remain distinct. With
no explicit or conventional lock, an undeclared registry dependency keeps the
existing local-index behavior; no network/public-registry transport is implied.
When a sidecar is present, the resolver retains its validated bytes and path in
the compilation resource ledger, so semantic-manifest freshness and cache
invalidation observe later `registry.lock` edits rather than dropping that
provenance after the tuple check. The foreground regression also rewrites a
valid v1 sidecar with an unrelated entry: the native artifact stays byte
identical while the semantic record changes and records the sidecar dependency.

`znc package registry-lock <source.zag> [--output registry.lock]` is the
bounded create-only generator for that explicit pin. It snapshots the
already-selected local registry entries for the root manifest and any nested
manifest that explicitly names the same sidecar, binds the selected
version/source and both raw-byte checksums (plus an optional
artifact-signature path), and never replaces an existing output.
`tests/run_package_registry_lock_generator.sh` proves root and nested
generation, explicit post-generation consumption, checksum-valid nested
mutation rejection, and replacement refusal; it does not provide network
fetching or version solving.

## Current boundary

The compiler now enforces deterministic local lock entries and raw checksums for
explicit vendored `pkg:` modules, every discovered relative `.zag` import, and
every `#embed` asset below each vendor root. Ordinary sibling development
imports remain unlocked. The package slice does not snapshot non-Zag assets,
solve competing version ranges or identify revisions, fetch source, or provide
complete graph/revision authority. `docs/PACKAGE_SIGNATURES.md` documents the
explicit verifier and opted-in signed local-registry path. Locked vendor and
registry entry modules, transitive relative modules, and embedded resources use
retained descriptor-bound no-symlink reads. Ordinary unlocked sibling imports
retain normal
kernel symlink semantics. The local registry mode only consumes a
reviewed on-disk index and remains network-free. A present conventional
`registry.lock` is consumed automatically from the nearest manifest chain,
while nonstandard lock paths remain explicit. This is a truthful
offline/vendor/registry-lock reproducibility slice, not the complete package
capability or a supply-chain authenticity system. Lock generation, public
registry fetch/transport, complete revision/version solving, and broad
package-policy integration remain outside this contract.
