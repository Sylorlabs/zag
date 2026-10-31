# Zag for VS Code

Syntax highlighting, diagnostics, completion, hover, and go to definition for Zag.

## Release installation

Install the `zag-lang.vsix` attached to a Zag release, then ensure `zag-lsp` is
on `PATH`. `sudo make install` from `zag-poc/` installs the language server.

```sh
code --install-extension zag-lang.vsix
```

## Building the client from source

VS Code 1.85 or later, and the Zag LSP binary on your PATH.

Build it from the compiler tree:

```sh
cd zag-poc
./znc selfhost/lsp/zag-lsp.zag -o zag-lsp
cp zag-lsp ~/.local/bin/
```

If the binary lives somewhere else, set `zag.serverPath` in VS Code settings.

The repository pins the client build through `package-lock.json`; no global
`vsce` install is required:

```sh
cd editors/vscode
npm ci
npm run install:local
```

Node.js is required only to rebuild the VS Code client. It is not a Zag
compiler, bootstrap, or application dependency.

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `zag.serverPath` | `zag-lsp` | Path to the LSP server binary |
| `zag.trace.server` | `off` | LSP trace level |

## Example

```zag
fn process(buf: []f32) void @realtime {
    let i: i32 = 0;
    while (i < buf.len) {
        buf[i] = buf[i] * 0.5;
        i = i + 1;
    }
}
```

Annotations like `@realtime` are checked at compile time. The compiler rejects code that breaks the declared capability.
