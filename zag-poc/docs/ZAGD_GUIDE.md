# `zagd` guide

## Persistent user service

Ordinary `znc` source commands automatically start the project daemon and it
remains resident. To start it at Linux user login and restart it after an
unexpected exit, install the optional project-specific systemd user service:

```sh
tools/zagd-user-service.sh install app.zag adaptive
```

After `make install`, the equivalent system-wide command is:

```sh
zagd-user-service install app.zag adaptive
```

The service runs `zagd` in the foreground under systemd with `Restart=always`,
one-second restart delay, a five-restart-per-minute backoff, `Nice=10`, low CPU
weight, no elevated privileges, no network namespace, no device access, and the
selected root source. `MemoryHigh` starts reclamation pressure before the hard
`MemoryMax`; swap remains disabled and the daemon's own `RLIMIT_AS` matches the
same configured memory budget.
The generated unit byte-escapes its executable, root, and source arguments, so
spaces and shell-significant characters in a project path cannot change unit
syntax. Its runner rereads the supported daemon settings from project-local
`.zagd.conf` each time it starts. The optional install mode is only a fallback;
an explicit `mode=` value in `.zagd.conf` wins.

Installation, reload, and restart first perform a bounded ownership handoff.
If an ordinary `znc` command already auto-started the project singleton, the
launcher requests its normal clean shutdown and verifies that its lock was
released before systemd starts the supervised replacement. The service runner
repeats that check immediately before `zagd` starts, closing the race with a
foreground compiler command. A daemon that does not release ownership causes
the service command to fail instead of repeatedly launching a second daemon
that exits with singleton status 6. Unit shutdown itself is bounded to five
seconds.

After editing ordinary policy such as mode, stability window, cache ceiling, or
notifications, apply it without reinstalling:

    tools/zagd-user-service.sh restart app.zag

For a `max_memory_bytes` change, use `reload` instead: it atomically
rewrites the private unit, reloads systemd, and restarts the daemon so both its
`RLIMIT_AS` and systemd `MemoryMax` match the new value.

    tools/zagd-user-service.sh reload app.zag

`mode=off` is a deliberate service stop, represented by a
`RestartPreventExitStatus` rather than an `Restart=always` loop. Set a
non-off mode and use `restart` to resume. Use `status` or `uninstall` with
the same root source to inspect or remove the service. This optional service
affects availability, not compiler correctness: foreground builds still work
without it.

Use `shutdown` to stop an installed service without disabling or removing it:

    tools/zagd-user-service.sh shutdown app.zag

Status: Linux daemon lifecycle, content tracking, and bounded background semantic
rechecking implemented, 2026-07-24.

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

Start a project with the validated bounded policy template:

```sh
cp examples/zagd.conf .zagd.conf
# after make install:
cp /usr/local/share/zag/zagd.conf.example .zagd.conf
```

The template keeps `mode=adaptive`, `idle_deep=true`, one worker, advisory
normal-Zag notices, no background GPU/network use, and Script-only automatic
defaults. `script_optimization=automatic` never bypasses foreground validation;
`regular_optimization=review` never changes regular-Zag code without explicit
acceptance. `objective=runtime` is the only implemented objective.
`trust_mode=stable` reserves the fixed-verifier policy; the current foreground
validator is linked into the compiler image, and no independent generational
verifier is claimed. Edit the one value you need; an explicit compiler flag
still wins, and `mode=off` is the easy persistent opt-out.

The checked `selfhost/zagd_generation.zag` foundation is narrower than an
optimizer-generation implementation. Its standalone test can persist immutable,
flat, content-addressed manifests with no payload, current/last-known-good
pointers, a three-success canary counter, and three-crash quarantine plus
rollback. Every record is checksum-validated, says
`executable_authority=false` and `generation_execution=disabled`, and falls back
to the release-linked foreground identity after missing, stale, mutated,
truncated, or inconsistent state. The production daemon does not import this
module or execute its records; status therefore remains
`optimizer_generation=unimplemented`. Worker synthesis, isolated generation
execution, verifier evolution, canary builds, and promotion are still
unavailable, so the ZagScript capability-matrix row remains `unavailable`.

`tests/run_zagd_config_template.sh` verifies both the exact shipped defaults
and acceptance by the foreground policy parser.
`stability_window_ms` controls the daemon's stable-read delay. Adaptive and deep
run deterministic bounded planner budgets; the current incomplete 1.0 matrix
does not claim equality saturation, generational self-modification, or a
complete whole-program optimizer merely because their policy values are
represented. Adaptive `idle_deep=true` does schedule one bounded deep
measurement attempt after 30 seconds of quiet, but it does not automatically
select a transformed foreground artifact.

Deep finalist execution is separately explicit. Put the reviewed executable
paths in `.zagd.deep-reference` and `.zagd.deep-finalist` (one relative-to-root
or absolute path per file), then select deep mode. The daemon runs three bounded
reference/finalist pairs only for the current valid semantic snapshot and writes
`.zag-cache/zagd/deep-measurement.record` only when every pair has identical
stdout, stderr, exit status, terminating signal, and success state. A stop
request or root/imported-module change between executions prevents persistence.
The measurement is bound to the whole semantic/module graph and active CPU cache
key and explicitly has no foreground authority. Removing either control file
disables execution; adaptive and light modes never execute them.

Regular Zag consumes the service as warnings and suggestions only. Zag Script
may apply the supported allocator/CPU/device/layout defaults when source and CLI
leave them unspecified. The allocator choices are `script_process_arena`
(default) and `script_bounded_heap` (per-allocation blocks with deterministic
generated-shutdown frees). Explicit command-line choices always win, and changing
project defaults requires only editing `.zagd.conf` and issuing the next source
command; the daemon never rewrites source.

`znc suggest --format text|json` accepts only a checksum-valid semantic record
whose complete module-node set still matches disk. A stale dependency or corrupt
record yields no recommendation. JSON recommendations include `id`,
`supported`, `automatic`, `confidence`, `evidence_basis`, `evidence`, `action`,
`validity`, and `rejected_reason`; the envelope records
`source_changes=false`, `checksum_bound=true`, `module_graph_current=true`, and a
supported count for agent-safe consumption. Allocation-effect review is a real
human advisory but does not by itself infer lifetime, byte size, or a
transformation. A separate `proven-buffer-lifetimes` advisory is available for
the compiler's deliberately narrow AST proof: statement-ordered local
`zalloc`/`zalloc_i` constant allocations with exactly one matching direct free
and no shadow, alias, escape, whole-buffer call exposure, control-flow crossing,
or use after free. It reports exact Linux x86-64 byte capacities and is always
`automatic=false` and `source_changes=false`. The analysis considers at most 64
candidate buffers per function and emits only adjacent valid reuse-chain pairs;
larger cases receive no lifetime advice instead of unbounded work. Buffer reuse
remains an explicit unsupported executable alternative until a transform and
equivalence proof exist; arena rewriting, layout rewriting, CPU chunking, and
GPU placement also remain unsupported rather than automatic claims.

`znc optimize --preview [--format text|json]` is a read-only inspection alias
for those same checksum-bound advisory facts. It never starts a transformation,
rewrites source, changes an allocator, or grants planner records executable
authority. `--apply`, `--in-place`, `--write`, `--output`, `-o`, and other
unrecognized arguments reject with a diagnostic; only `--preview`, `--format`,
and the one-shot `--no-zagd` inspection flag are accepted.

When deep mode receives a matching `.zagd.profile`, it may also write a
checksum-bound `profile-plan.record`. The v3 plan binds its samples to the
daemon executable, exact sibling `znc` image, compiler version, semantic source
and complete graph, and CPU cache key. Each hot label must match a current
semantic function declaration; absent labels and unavailable features are
shown as rejected rows with a reason. A foreground build automatically reads
this record as metadata only. It rejects any compiler, parsed-module, source,
graph, semantic-identity, target, row, or checksum mismatch and never feeds the
record into code generation or the machine-cache key. Use `--profile-report`
to inspect the decision or `--no-zagd-profile` to disable the read.
`znc suggest` exposes a current profile plan as
`profile-guided-hot-regions`, always with `supported=false` and
`automatic=false`: it is reviewable PGO evidence, not a PGO rewrite. It does
not alter source, enable packed SIMD, change the foreground CPU target, reuse
machine code, or run GPU work.

In adaptive or deep mode, the candidate record may additionally show
`script-default-cpu` for a Script root. This is not a daemon optimization pass:
it reports the real foreground behavior already implemented by `znc` when the
project CPU default and daemon target have the same feature-qualified identity.
It is applicable only when the later foreground command omits `--cpu`; an
explicit CPU flag wins, and an identity mismatch is rejected. The record stays
`advisory=true`, `source_changes=false`, and has no authority over machine-code
or cache reuse.

The default `notifications=advisory` lets a successful normal-Zag command emit
one short warning only when a supported allocation-effect review exists.
Set `notifications=errors_only` in `.zagd.conf` to make routine foreground
commands quiet without disabling analysis. Unsupported constant-fold/inline
planner scaffolding never triggers the warning.

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
Linux inotify queue overflow cancels current advice and invokes a bounded full
source-tree rescan; only two identical scans may replace the snapshot. If a file
keeps changing through all bounded retries, status remains `stabilizing` and the
previous snapshot remains published. Creating `.zagd.rescan` requests the same
conservative recovery path. Project-internal symlinks are ignored and never
followed outside the project root.
Background checks use `--no-zagd`, so they cannot recursively start a daemon.
Failed checks mark the snapshot invalid and cannot authorize an executable. The
semantic artifact index persists stable declaration, public/effect, layout,
compiler, target, and source identities with conservative invalidation.
`detail_level=compact` is used for large merged units: it keeps exact
declaration/call/type/layout/import/module graph data and raw module hashes while
explicitly marking expression/value/copy and local buffer-lifetime witnesses
unavailable. Suggestion output exposes that distinction and never infers a fact
from an omitted witness. The index does not authorize executable reuse.

The separate foreground compiler cache may skip backend lowering only after
exact compiler image/version, project root, root/import token streams, current
complete semantic graph, target/CPU features, ABI/pipeline, resolved
strict/Script policy, lengths, and record/code/data checksum validation. Its v4
triplet is read only from real directories and regular non-symlink files and is
published with unique staging names, payloads first, record last. Static
archives, debug sections, hot metadata, and ELF assembly remain fresh.
Executable authority remains with the current compiler invocation. The daemon's
disk ceiling accounts for the machine record, code, and data via file metadata;
an over-budget triplet is removed as a unit without reading the payload merely
to size it.

## Correctness boundary

Content, not path or modification time, identifies source. Snapshot composition
requires canonical project-relative path order. The persisted
`zagd-snapshot-v2` record explicitly binds the selected root module and its raw
content hash, project-root identity, complete semantic-graph identity when one
is available, full parent identity, validity, and every file hash. Its
monotonic timestamp is metadata and is explicitly excluded from the content
identity. Unknown analysis is classified conservatively. A cache record is
rejected when its schema, checksum, completeness, root/source/graph binding,
compiler identity, snapshot identity, target identity, or recomputed payload
identity does not match. Old snapshot formats are safe misses and are replaced
only after a new stable scan.

Raw per-module content hashes remain in the manifest for current-file
validation, but semantic graph identity is built from canonical declaration
identities, call/type/layout edges, module names, and import topology. A
comment-only edit therefore makes the old record stale until the foreground
compiler republishes it, while the newly validated semantic graph and
artifact/codegen identity remain unchanged.

Cache acceptance is analysis infrastructure only. It does not authorize stale
machine code, and deleting all cache state must affect performance rather than
program correctness.

## Testing the implementation

```sh
tests/run_zagd_core.sh
tests/run_zagd_incremental.sh
tests/run_zagd_profile.sh
tests/run_zagd_daemon.sh
tests/run_zagd_identity.sh
tests/run_zagd_watcher_correctness.sh
tests/run_zagd_memory_stress.sh
tests/run_zagd_buffer_lifetime.sh
tests/run_zagd_background_semantics.sh
tests/run_zagd_executor.sh
tests/run_zagd_benchmark_policy.sh
tests/run_zagd_generation.sh
tests/run_zagd_deep_integration.sh
tests/run_zagd_product.sh
tests/run_zagd_user_service.sh
```

The tests compile and execute the implementation using `./znc`. They cover
stable identity,
path-sensitive snapshots, stability timing, all change classes, successful cache
acceptance, partial-record rejection, stale-snapshot rejection, and tampered
payload rejection, recursive and atomic-save events, restart reuse, stable-source
background checks, invalid snapshots, singleton/PID-reuse identity, overflow
recovery, identical rewrites, rapid patch sequences, symlink policy, repeated
edit memory bounds, idle CPU, service policy, deep finalist equivalence, and
recovery after a later valid edit. The generation test is deliberately
standalone: it covers metadata mutation/truncation, compiler staleness, bounded
canary promotion, crash-loop quarantine, predecessor retention, and rollback
without granting the daemon or any stored bytes execution authority.
