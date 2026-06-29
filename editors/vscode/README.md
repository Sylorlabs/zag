# Zag Language — VS Code Extension

Syntax highlighting, real-time diagnostics, completion, hover, and
go-to-definition for the [Zag](../../zag-poc/README.md) systems language.

## Requirements

- VS Code 1.85 or later
- The Zag LSP server binary on your PATH as `znc-lsp`
  (or configure `zag.serverPath` to point to its absolute path)

## Building the LSP server

```sh
cd zag-poc
./znc selfhost/lsp/server.zag -o znc-lsp
cp znc-lsp ~/.local/bin/   # or anywhere on your PATH
```

## Installing the extension

Until the extension is published to the Marketplace, install it from source:

```sh
cd editors/vscode
npm install
npm run compile
# In VS Code: Extensions → "..." → Install from VSIX...
# Or use the VS Code CLI:
code --install-extension zag-lang-0.1.0.vsix
```

To package a VSIX:
```sh
npm install -g @vscode/vsce
vsce package
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `zag.serverPath` | `znc-lsp` | Path to the Zag LSP server binary |
| `zag.trace.server` | `off` | LSP protocol tracing (`off`/`messages`/`verbose`) |

## Features

- **Syntax highlighting** — keywords, types, annotations (`@realtime`, `@pure`,
  …), string literals, numeric literals, `@import`/`@link` directives
- **Real-time diagnostics** — effect/capability violations are highlighted as
  errors as you type (powered by the Zag capability checker in `sema.zag`)
- **Hover** — hover over a function name to see its signature and effect annotations
- **Go-to-definition** — `F12` jumps to the declaration of a function or struct
- **Completion** — function and struct names in scope are suggested as you type
- **Rename** — `F2` renames a function or variable across the file

## Language overview

Zag is a systems language with a compiler-proven effect/capability system.
Annotations like `@realtime`, `@noalloc`, `@pure`, and `@total` are checked
at compile time — the compiler rejects code that violates the declared
capabilities of a function.

```zag
// @realtime fn: no heap, no I/O, no locks allowed
@realtime
fn process(buf: []f32) void {
    let i: i32 = 0;
    while (i < buf.len) {
        buf[i] = buf[i] * 0.5;
        i = i + 1;
    }
}
```
