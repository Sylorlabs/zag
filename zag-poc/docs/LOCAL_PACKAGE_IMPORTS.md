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
zagkit = { path = "../zagkit" }
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
3. appends the explicit module path from the `pkg:` import; and
4. requires the resulting `.zag` file to exist before parsing it.

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

This resolver is not a filesystem containment sandbox. Declared dependency
roots may use parent segments, and filesystem symlinks are followed normally.
Projects must review those declared paths and links to ensure they remain within
the workspace boundaries the project intends.

## Locked vendored mode

A dependency stored beneath the consuming project can opt into compiler-enforced
offline locking:

```ini
[deps]
zagkit = { path = "vendor/zagkit", mode = "vendor" }
```

Vendor mode requires `zag.lock` beside that `zag.mod`. Its first version is a
small, canonical, module-granular format. The separators on `entry=` lines are
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
all explicit `pkg:` imports reached from the source, requires each matching
dependency to use `mode = "vendor"`, reads the exact module bytes, and emits
the canonical sorted entries below the `format=zag-local-lock-v1` header. Use
`--output` to choose a new destination. It does not infer ordinary
source-relative imports, lock non-Zag assets, solve versions, or contact a
registry; those remain outside this bounded generator contract.

Entries are strictly bytewise sorted by alias, root, then module. Blank,
duplicate, reordered, unknown-record, unknown-alias, malformed, noncanonical
decimal, and root-mismatch entries fail closed. A canonical comment line starts
with exactly `# `, contains only printable ASCII after that prefix, and is
ignored for entry ordering while remaining part of the lock's raw provenance
identity. Every entry must name exactly one `mode = "vendor"` dependency, use
that dependency's exact declared root, name an existing traversal-free `.zag`
module, and checksum at most 8 MiB of raw module bytes. A lock is bounded to 256
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

This is still not filesystem containment: a reviewed vendor directory may
contain symlinks, and normal kernel symlink semantics apply. Ordinary local
dependencies without `mode = "vendor"` retain the sibling-path behavior above
and do not implicitly become locked.

## Current boundary

The compiler now enforces deterministic local lock entries and raw checksums for
explicit vendored `pkg:` modules, while preserving unlocked sibling development
imports. It does not provide a lock/update generator, recursively require every
ordinary source-relative import beneath a vendor root to appear in the lock,
snapshot non-Zag assets, resolve versions, identify revisions, verify package
signatures, fetch source, speak a registry protocol, or contain symlinks. This
is a truthful offline/vendor reproducibility slice, not the complete package
capability or a supply-chain authenticity system.
