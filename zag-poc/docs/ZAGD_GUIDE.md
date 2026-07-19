# `zagd` guide

## Persistent user service

Ordinary `znc` source commands automatically start the project daemon and it
remains resident. To start it at Linux user login and restart it after an
unexpected exit, install the optional project-specific systemd user service:

```sh
tools/zagd-user-service.sh install app.zag adaptive
```

The service runs `zagd` in the foreground under systemd with `Restart=always`,
`Nice=10`, no elevated privileges, no network use, and the selected root source.
The project `.zagd.conf` remains the ordinary policy location. Re-run `install`
to change the root or service mode; use `status` or `uninstall` with the same
root source to inspect or remove it. This optional service affects availability,
not compiler correctness: foreground builds still work without it.

Status: Linux daemon lifecycle, content tracking, and bounded background semantic
rechecking implemented, 2026-07-18.

`zagd` is an automatic, editor-independent continuous analysis service whose
availability is correctness-independent. `znc` starts its sibling daemon for
ordinary source commands and exposes `watch`,
`status`, `shutdown`, and advisory `suggest`. Startup failure warns but never
changes foreground compiler correctness.

Use `.zagd.conf` with `mode=off`, `mode=light`, `mode=adaptive`, or `mode=deep`
to select automatic startup behavior. A subsequent source command applies a
mode change, including stopping an existing daemon for `mode=off`. The
`mode=off` setting is the persistent project opt-out for automatic background
startup; it is already covered by product tests for fresh builds and for
stopping a running project daemon. No second opt-out setting is required.
`stability_window_ms` setting controls the daemon's stable-read delay. Adaptive
and deep run deterministic bounded planner budgets; they are not a complete
whole-program optimizer or an unbounded idle-time search.

Deep finalist execution is separately explicit. Put the reviewed executable
paths in `.zagd.deep-reference` and `.zagd.deep-finalist` (one relative-to-root
or absolute path per file), then select deep mode. The daemon runs three bounded
reference/finalist pairs only for the current valid semantic snapshot and writes
`.zag-cache/zagd/deep-measurement.record` only when every pair has identical
stdout, stderr, exit status, terminating signal, and success state. A stop
request or source change between executions prevents persistence. Removing
either control file disables execution; adaptive and light modes never execute
them.

Regular Zag consumes the service as warnings and suggestions only. Zag Script
may apply the supported allocator/CPU/device/layout defaults when source and CLI
leave them unspecified. Explicit command-line choices always win, and changing
project defaults requires only editing `.zagd.conf` and issuing the next source
command; the daemon never rewrites source.

`znc suggest --format text|json` accepts only a checksum-valid semantic record
whose root source identity still matches disk. A stale or corrupt record yields
no recommendation. JSON recommendations include `id`, `automatic`,
`confidence`, `provenance`, `evidence`, and `action`; the envelope records
`source_changes=false` and `checksum_bound=true` for agent-safe consumption.

The implemented pure-Zag core in `selfhost/zagd.zag` and Linux service in
`selfhost/zagd_daemon.zag` provide:

- deterministic content identities;
- canonical snapshot identity composition;
- stability-window decisions from supplied timestamps and hashes;
- conservative change classes;
- quiet bounded configuration defaults; and
- fail-closed cache-record acceptance;
- recursive inotify observation, atomic-save handling, and ignored build/cache
  paths;
- transactional persistent snapshot/advisory records; and
- stable-source semantic rechecks by the sibling self-hosted `znc` process.

The policy core itself performs no filesystem I/O; the Linux daemon supplies it.
Events remain hints: the daemon waits for stability, reads complete content,
hashes it, ignores identical rewrites, and rechecks the final stable source.
Background checks use `--no-zagd`, so they cannot recursively start a daemon.
Failed checks mark the snapshot invalid and cannot authorize an executable. The
semantic artifact index persists stable declaration, public/effect, layout,
compiler, target, and source identities with conservative invalidation. It does
not substitute cached machine bytes into foreground output; executable
authority remains with the current compiler invocation.

## Correctness boundary

Content, not path or modification time, identifies source. Snapshot composition
requires canonical project-relative path order. Unknown analysis is classified
conservatively. A cache record is rejected when its schema, completeness, size,
compiler identity, snapshot identity, target identity, or recomputed payload
identity does not match.

Cache acceptance is analysis infrastructure only. It does not authorize stale
machine code, and deleting all cache state must affect performance rather than
program correctness.

## Testing the implementation

```sh
tests/run_zagd_core.sh
tests/run_zagd_daemon.sh
tests/run_zagd_background_semantics.sh
```

The tests compile and execute the implementation using `./znc`. They cover
stable identity,
path-sensitive snapshots, stability timing, all change classes, successful cache
acceptance, partial-record rejection, stale-snapshot rejection, and tampered
payload rejection, recursive and atomic-save events, restart reuse, stable-source
background checks, invalid snapshots, and recovery after a later valid edit.
