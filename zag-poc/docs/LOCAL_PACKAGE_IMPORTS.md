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
missing modules, malformed entries, and module paths containing `.` or `..`
segments. Dependency roots must be bounded relative paths using `/`; absolute,
home-expanded, backslash, colon, URL, and scp-like forms are rejected. Parent
segments remain valid in dependency roots so sibling declarations such as
`../zagkit` work. Package names and module paths are bounded, and module paths
must name a `.zag` file.

## Current boundary

This local resolver does not fetch source or provide a registry, semantic
version solver, lockfile, content checksum, signature authority, revision pin,
implicit package entry point, environment search path, or dependency update
command. Pin sibling or vendored source with the containing workspace's version
control and review changes directly. The full package capability therefore
remains unavailable until its separate reproducibility and trust contracts are
implemented and verified.
