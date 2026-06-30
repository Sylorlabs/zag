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

## Submit / track the upstream PR

1. Fork `github-linguist/linguist`.
2. Add the `languages.yml` snippet from `languages.yml.snippet`.
3. Register the grammar:
   ```bash
   script/add-grammar https://github.com/Sylorlabs/zag
   ```
   (or vendor `editors/vscode/syntaxes/zag.tmLanguage.json` manually).
4. Copy two samples from `zag-poc/examples/` into `samples/Zag/`.
5. Run `script/update-ids` and open a PR linking GitHub code search for `extension:zag`.

Linguist requires broad public usage (~2000 indexed `.zag` files). Until that
threshold is met, this repo uses `.gitattributes` to classify `.zag` as Zig for
highlighting and to exclude generated `*.zag.c` from language statistics.

## After merge

Replace the interim line in the root `.gitattributes`:

```gitattributes
*.zag linguist-language=Zig linguist-detectable
```

with:

```gitattributes
*.zag linguist-language=Zag linguist-detectable
```

GitHub refreshes linguist on its own release cadence (days to weeks after merge).