# `zagd` guide

Status: Linux daemon lifecycle and content tracking implemented, 2026-07-18.

`zagd` is an automatic, editor-independent continuous analysis service whose
availability is correctness-independent. `znc` starts its sibling daemon for ordinary source commands and exposes `watch`,
`status`, `shutdown`, and advisory `suggest`. Startup failure warns but never
changes foreground compiler correctness.

Use `.zagd.conf` with `mode=off`, `mode=light`, `mode=adaptive`, or `mode=deep`
to select automatic startup behavior. A subsequent source command applies a
mode change, including stopping an existing daemon for `mode=off`. The
`stability_window_ms` setting controls the daemon's stable-read delay. Adaptive and deep currently select
lifecycle modes only; broader planning engines remain future work.

The implemented pure-Zag core in `selfhost/zagd.zag` provides:

- deterministic content identities;
- canonical snapshot identity composition;
- stability-window decisions from supplied timestamps and hashes;
- conservative change classes;
- quiet bounded configuration defaults; and
- fail-closed cache-record acceptance.

The core performs no filesystem I/O. A future watcher must read complete files,
hash their contents, canonicalize path order, and pass observations into these
primitives. No current code claims inotify support, atomic cache writes,
persistent storage, dependency graph maintenance, incremental parsing, worker
cancellation, or idle CPU measurements.

## Correctness boundary

Content, not path or modification time, identifies source. Snapshot composition
requires canonical project-relative path order. Unknown analysis is classified
conservatively. A cache record is rejected when its schema, completeness, size,
compiler identity, snapshot identity, target identity, or recomputed payload
identity does not match.

Cache acceptance is analysis infrastructure only. It does not authorize stale
machine code, and deleting all cache state must affect performance rather than
program correctness.

## Testing the implemented core

```sh
tests/run_zagd_core.sh
```

The test compiles and executes the core using `./znc`. It covers stable identity,
path-sensitive snapshots, stability timing, all change classes, successful cache
acceptance, partial-record rejection, stale-snapshot rejection, and tampered
payload rejection.
