# GitHub Linguist — Zag language registration

GitHub only shows a language name, color, and syntax highlighting for `.zag` files
after **Zag** is registered in [github-linguist/linguist](https://github.com/github-linguist/linguist).

## Proposed registration

| Field | Value |
|---|---|
| Name | Zag |
| Extension | `.zag` |
| Color | `#2563eb` (blue) |
| Grammar | `editors/vscode/syntaxes/zag.tmLanguage.json` |
| Scope | `source.zag` |

## Upstream PR

Tracking PR: https://github.com/github-linguist/linguist/pulls?q=is%3Apr+zag

Grammar repository: https://github.com/Sylorlabs/zag-grammar

## Submit / update the upstream PR

1. Fork `github-linguist/linguist`.
2. Add the `languages.yml` snippet from `languages.yml.snippet`.
3. Register the grammar:
   ```bash
   script/add-grammar https://github.com/Sylorlabs/zag
   ```
   (or vendor `editors/vscode/syntaxes/zag.tmLanguage.json` manually).
4. Copy two samples from `zag-poc/examples/` into `samples/Zag/`.
5. Run `script/update-ids` and open a PR linking GitHub code search for `extension:zag`.

Linguist requires broad public usage (~2000 indexed `.zag` files). The upstream
PR may sit open until that threshold is met. Until it merges, the root
`.gitattributes` maps `*.zag` to **Zig** on github.com so files highlight
correctly. See the README "GitHub syntax highlighting" note.

## After merge

Change `.gitattributes` from:

```gitattributes
*.zag linguist-language=Zig linguist-detectable
```

to:

```gitattributes
*.zag linguist-language=Zag linguist-detectable
```

GitHub refreshes linguist on its own release cadence (days to weeks after merge).