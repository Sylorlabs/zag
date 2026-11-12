# NEXUS: the third path

This directory contains the smallest continuing learner for the NEXUS
directive. It is deliberately an experiment, not a claim of general
intelligence.

## Native substrate

`nexus.zag` uses one flat byte arena. Every record has an identity, kind,
operation, operands, confidence/version, and provenance parent. The same arena
stores:

- acquired relations;
- immutable observation records;
- predictions and contradictory outcomes;
- candidate investigations and selected queries;
- composed executable relations.

Edges are also arena records. The learner never receives a researcher-supplied
object identifier for the investigation. It scores a query derived from the
contradicted prediction and writes the selected investigation into the same
state.

## Run

From `zag-poc/`:

```sh
/Users/Shared/micah/Documents/TNN/.bin/znc \
  --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache \
  research/nexus/nexus.zag -o research/nexus/nexus-bin
research/nexus/nexus-bin unified
```

Modes include the original controls (`unified`, `no-cross`,
`knowledge-erased`, `investigation-erased`, `no-compose`, `fresh`, `modular`)
and NEXUS-02 developmental controls (`development`, `dev-no-pred`,
`dev-no-investigation`, `dev-no-learning`, `dev-all`, `dev-modular`).
`persist-write`/`persist-read` and `dev-persist-write`/`dev-persist-read`
exercise separate-process persistence.

`persist-write PATH` writes the complete learner arena; a separate
`persist-read PATH` process reloads it and composes using the persisted object
identities.

## Result

The frozen run and causal interpretation are in `REPORT.md`. The native
interface contract intended for the TNN research programs is in
`NATIVE_INTERFACE.md`.

## Toolchain boundary

The checked-in Zag macOS seed is `znc 2026.07.0-dev`, SHA-256
`3093d12dba9cc81b1dee69d2d4e604158d093b58f8f01ddab26c0f4297029956`.
The current seed rejects the edition-2027 ownership form while compiling the
current self-host source, so this prototype is compiled in the repository's
edition-2026 compatibility mode with the native macOS target. The report
records this as an implementation boundary; no edition-2027 support claim is
made.
