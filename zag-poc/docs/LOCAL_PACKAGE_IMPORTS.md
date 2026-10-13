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

## Parser-backed source closure

`znc --emit-closure` uses the actual compiler parser to capture the transitive
source inputs, explicit resolved imports, retained resources, and dependency
manifests. The current CLI emits `zag-source-closure-v1`, replacing the earlier
manifest-only description of `zag-dependency-closure-v1`.

Set `ZNC` to the current compiler executable. `znc` is the supported name;
`zagc` is retired, with no new compatibility alias.

```sh
"$ZNC" --emit-closure src/main.zag --output source-closure.manifest
"$ZNC" emit-closure src/main.zag
```

The first form requires a new output path; `-o` also works. Without an output
option, closure text goes to stdout. Source-first spelling (`"$ZNC"
src/main.zag --emit-closure`) is also accepted. Parsing and closure validation
finish before the compiler publishes closure bytes. Shell redirection has its
own create/truncate behavior; use `--output` for compiler-enforced create-only
publication.

After `format=zag-source-closure-v1` and `root=<absolute lexical path>`, the
following tab-separated records are sorted by their complete escaped bytes and
deduplicated:

| Record | Fields after `=` |
|---|---|
| `source` | path, `sha256:<digest>`, raw byte count |
| `resource` | path, `sha256:<digest>`, raw byte count |
| `manifest` | path, `sha256:<digest>`, raw byte count |
| `import` | importer path, resolved source path, original import specifier |
| `package` | declaring manifest, child manifest, alias, declared path, mode |
| `pin` | manifest path, optional `sha256:<compiler digest>` (empty when absent) |

Source and resource hashes cover the exact parser-retained snapshots, not a
later reopening of those files. This includes loaded relative, `std:`, and
`pkg:` modules, any injected Script preludes, embedded resource bytes, and
package manifest/lock buffers retained by package resolution. Import records
are exactly the explicit edges retained in `CompilationUnit.imports`; resources
are inputs, without invented resource-to-importer edges. The closure records
hashes and sizes, not an archive of the input contents.

For every loaded source, the closure also discovers its nearest manifest and
recursively visits declared local dependencies, including declarations not
selected by an explicit source import. Supplemental manifest snapshots must
agree with any same-path parser-retained bytes. Every manifest has a `pin`
record, including an empty pin when optional toolchain identity is absent. A
standalone source does not require a manifest. An embedded asset merely named
`zag.mod` is not automatically treated as package metadata.

Paths are absolute and lexically normalized. Equivalent relative/absolute
entry spellings agree when they resolve to the same inputs; moving a checkout
or changing resolver layout can change the closure. This is not symlink
containment or relocation-independent identity. Fields escape `%` and
non-printable/non-ASCII bytes as `%hh`, preventing record injection.

Missing imports/resources, invalid vendor locks, malformed dependency graphs,
cycles, inconsistent same-path snapshots, and exceeded limits fail closed.
Bounds include 64 MiB per input, 256 MiB of recorded input bytes, 8,192 inputs,
65,536 collected records, source depth below 256, and the manifest walk's
256-manifest limit.

The reusable APIs in `selfhost/source_closure.zag` are
`source_closure_from_unit(path, cwd, unit)` and
`source_closure_from_unit_pinned(path, cwd, unit, expected_compiler_pin)`.
They borrow the compilation unit and require its absolute resolver CWD;
`source_closure_load(path, cwd)` is the parse-once convenience entry used by the
CLI. Check `SourceClosureResult.valid`, read `error` on failure, and release
owned text with `source_closure_release`. Parser errors retain the parser's
exit-on-error contract.

## Toolchain identity pins

A project that must be built only by one compiler image may declare an exact
SHA-256 pin in each manifest that participates in the closure:

```ini
[toolchain]
compiler = "sha256:<64 lowercase hexadecimal digits>"
```

For ordinary builds, the root manifest graph is checked against the running
compiler image before daemon startup, parsing, cache lookup, or target dispatch.
The compiler also checks manifests associated with actual loaded source paths,
including relative and `std:` imports, after parsing. An unavailable image or
mismatch for a declared pin fails closed. Manifest pins remain optional.

Closure inspection (`--emit-closure` and the unpinned API) records pins without
enforcing them against the running image. The pinned closure API requires a
canonical `sha256:<64 lowercase hex>` expected identity and checks each declared
pin against the same manifest snapshot it records. It rejects an invalid or
empty expected pin even if all manifests are unpinned; the caller supplies the
actual compiler identity.

Native build evidence additionally requires CLI `--compiler-pin` with **64
lowercase hexadecimal digits, without `sha256:`**, even when no manifest has a
toolchain pin. The driver verifies the running image and uses the pinned
closure API. See [Native evidence](NATIVE_EVIDENCE.md) for the bounded build
workflow, receipt verification, and replay APIs. Hash pins establish exact-byte
integrity relative to a trusted expected value; they do not authenticate a
compiler publisher or package author.

## Current boundary

The compiler now enforces deterministic local lock entries and raw checksums for
explicit vendored `pkg:` modules, while preserving unlocked sibling development
imports. The create-only `package lock` generator is bounded as described above;
there is no general lock-update or version-solving workflow. It does not
recursively require every ordinary source-relative import beneath a vendor root
to appear in the lock, snapshot unreferenced non-Zag assets, resolve versions,
identify revisions, verify package signatures, fetch source, speak a registry
protocol, or contain symlinks. This is a truthful offline/vendor reproducibility
slice, not the complete package capability or a supply-chain authenticity system.
