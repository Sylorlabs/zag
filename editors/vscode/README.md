# Zag for VS Code

Syntax highlighting, diagnostics, completion, hover, and go to definition for Zag.

## Requirements

VS Code 1.85 or later, and the Zag LSP binary on your PATH.

Build it from the compiler tree:

```sh
cd zag-poc
./znc selfhost/lsp/zag-lsp.zag -o zag-lsp
cp zag-lsp ~/.local/bin/
```

If the binary lives somewhere else, set `zag.serverPath` in VS Code settings.

## Install the extension

```sh
cd editors/vscode
npm install
npm run compile
vsce package
code --install-extension zag-lang-0.1.0.vsix
```

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