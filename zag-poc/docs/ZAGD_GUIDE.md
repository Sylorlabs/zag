# `zagd` guide

Status: reusable correctness core only, 2026-07-18.

`zagd` is intended to be an optional, editor-independent continuous analysis and
planning service. No daemon process, Linux watcher, `znc watch`, `status`, or
`suggest` command is implemented yet. Foreground builds neither require nor
consult a daemon.

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

