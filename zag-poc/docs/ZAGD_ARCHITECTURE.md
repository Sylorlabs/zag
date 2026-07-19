# `zagd` architecture

Status: Linux light-mode implementation with bounded advisory-planner
foundations, 2026-07-18. Recursive inotify watching, stable content hashing,
transactional advisory snapshots, restart validation, status, suggestion,
shutdown, and source-command auto-start are implemented. Complete semantic
dependency reconstruction and general deep search are not.

## Purpose and correctness boundary

`zagd` is an automatically started, correctness-independent project-level
analysis and planning service driven by filesystem state. Editors are not part
of the protocol. A foreground `znc` build always remains authoritative and works
when the daemon is absent, stopped, stale, or has a corrupt cache.

The daemon never rewrites source. Regular Zag receives facts and suggestions.
Zag Script may consume a valid plan only for choices left unspecified, and the
foreground compiler revalidates the plan.

## Watcher and stable reads

A target-neutral watcher interface exposes create, modify, delete, rename and
overflow/rescan events. Linux uses inotify where practical. Events are hints,
not source identity. After an event, the service applies a short configurable
stability window, reads the complete candidate, hashes its contents, compares
the previous hash, and publishes a snapshot only from the observed content.

Atomic rename saves, deletion/recreation and rapid patch sequences coalesce by
path and content. Identical rewrites produce no semantic invalidation. Event
queue overflow triggers a bounded project rescan. Temporary files, build output
and the daemon cache are ignored by explicit rules. Symlinks default to recording
the link and resolved target identity without watching outside the project root;
other behavior requires explicit configuration.

## Snapshot model

Each immutable snapshot records a content-derived identifier, root module,
canonical project-relative paths and hashes, module/dependency graph, validity,
parent identifier, timestamp, compiler version, options and target profile.
Timestamps are metadata and do not establish identity.

Parsing may report transient invalid states. Medium and deep work runs only on a
stable, semantically valid snapshot. A newer snapshot cancels obsolete work.
`checkpoint` may force consideration of the current stable content but is not a
normal correctness requirement.

## Dependency and invalidation model

Stable declaration and function identities are required before fine-grained
reuse. The dependency graph records file to declaration, type/layout, function,
caller, effect, optimization region and generated-code edges.

Change classification is conservative:

| Change | Minimum invalidation |
| --- | --- |
| byte change proven comment/format-only | parse presentation only; retain sema/codegen after validation |
| private function body | function facts/code and transitive caller plans |
| public signature, effect or layout | all semantic and ABI dependents |
| root profile or root statements | script lowering and runtime configuration |
| compiler/options/target/features | all affected target-dependent records |
| unknown classification | dependents conservatively |

No cached executable is accepted solely because a path or modification time
matches.

## Modes and state machine

`off` performs no daemon analysis. `light` maintains hashes and snapshots and
runs a fresh self-hosted parse/type/effect check after stable source changes.
This is background semantic rechecking, not an in-process incremental parser.
`adaptive` evaluates a bounded set of allocation, buffer reuse, layout and
CPU-region candidates after stability. `deep` is explicit and has a larger but
still hard candidate budget. Current deep work does not run profiling,
microbenchmarks, or broad equivalence search. Invalidated work transitions
immediately to cancelled and its result cannot be published.

The service states are starting, idle, stabilizing, analyzing-light,
analyzing-adaptive, analyzing-deep, cancelling, recovering and stopped. At most
one snapshot is current; results name their snapshot and validity conditions.

## Cache records

Cache keys include compiler/version/schema, source and dependency hashes,
module/declaration identity, semantic options, target and feature profile, and
relevant runtime policy. Records include provenance (`proven`, `derived`,
`measured`, `estimated`, `unknown`) and validity conditions. Writes are
transactional: temporary record, checksum, atomic rename. Bad schema, checksum,
missing dependency or impossible graph edge causes record rejection and local
recomputation. Cache deletion changes performance only.

## Resource policy

Default operation is one low-priority worker, no network, no GPU, no deep
search, errors-only notifications, bounded memory and disk cache, and prompt
cancellation. The event loop blocks in the kernel when idle, so idle CPU should
approach zero. Foreground builds and tests take priority. Cache eviction is
content-record eviction, never source deletion.

An initial project configuration file may set mode, stability interval,
workers, memory/cache budgets, ignore rules, deep-search policy and notification
level. Unsupported or malformed settings fail closed to documented quiet
defaults and produce a diagnostic.

## Commands and protocol

`znc watch` owns or connects to the project daemon. Ordinary source commands
ensure the configured singleton is running unless `mode=off` or the one-shot
`--no-zagd` override is present. `status` reports PID or
equivalent instance identity, mode, current snapshot, validity, queued/running
work, budgets and cache health. `suggest` validates the semantic-record checksum
and current root source hash before emitting deterministic text or JSON.
Implemented patterns include proven constant-return folding, effect-free leaf
inline candidates, allocation-effect review, and unresolved local-type
witnesses. Every JSON item states evidence, confidence, provenance, action, and
whether it is an automatic Script default. Regular Zag always remains
`automatic=false` and `source_changes=false`; Script allocator/device/layout
defaults are automatic only where the corresponding source choice is absent.
Shutdown is explicit and graceful. The transport is local-only,
versioned, project-scoped and must authenticate filesystem ownership before any
state-changing control message.

## Planner layers

Planning proceeds through exact constraints, deterministic validated patterns,
bounded candidate generation/pruning, a target-qualified cost model, then
optional finalist benchmarks. Correctness/effects/features/memory constraints
are hard filters. Expected runtime is the default objective, but a faster plan
is rejected when it exceeds memory or stability limits. Random exploration is
not a default policy.

Adaptive/deep mode generates a fixed, bounded set of concrete buffer-reuse,
arena-temporary, compiler-owned layout, and CPU-chunk candidates from semantic
facts. Invalid, unsupported, non-equivalent, over-memory, and strictly
dominated candidates are removed deterministically. Records are keyed by exact
source and target hashes and remain advisory with `source_changes=false`.
Script candidates become automatic only for the corresponding unspecified
allocator or device choice.

Deep measurements are accepted only when explicitly supplied with at least
three runs and exact candidate/source/target identities. Stale, malformed,
cancelled, non-deep, and mismatched measurements are ignored. Accepted timings
replace estimates with measured provenance; they never authorize source
rewrites or bypass foreground equivalence checks.

Every suggestion identifies evidence, confidence, estimated benefit/cost,
rejected alternatives and invalidation conditions. Automatic script choices
use the same report format. Regular Zag plans remain advisory except existing
semantics-preserving backend optimization.

## Initial implementation order

Implement watcher abstraction and event tests, content hashing, immutable
snapshots, conservative module invalidation, transactional bounded cache,
status/shutdown, then light analysis. Adaptive and deep planning begin only
after stale-cache and rapid-update stress tests prove the correctness boundary.

## Current incremental-index boundary

The implemented advisory snapshot record persists canonical project-relative
paths plus content, comment-insensitive semantic, public-declaration-shape and
root-profile fingerprints. Restart reuse requires a valid checksum, the current
compiler version, target and exact planner mode. It restores the per-file index,
so identical rewrites remain non-invalidating after restart and a later public
shape edit remains distinguishable from a private body edit. Unsafe paths,
truncation, corruption, stale configuration or an inconsistent file count make
the whole index a cache miss; they never authorize generated code.

This is not yet a complete semantic dependency graph. Lexical `@import`
discovery does not model every merged-module or conditional-resolution case.
The foreground compiler can publish checksum-bound semantic declaration facts;

## Incremental artifact index

The daemon persists `.zag-cache/zagd/artifact.record` transactionally. This is
an advisory index, never executable authority. Its identity combines the
self-hosted compiler version, explicit target profile, public/effect/layout
identities, and stable declaration body identities. Source line locations are
diagnostic metadata and do not perturb an artifact identity, so comment-only
line movement preserves codegen candidates.

Reuse is fail-closed: format, completeness, advisory authority, compiler,
target, exact semantic source hash, and the record checksum must all validate.
A mismatch is a cache miss and foreground compilation proceeds normally.
Private body changes invalidate the declaration and its transitive callers;
public layout changes invalidate layout/codegen dependents; comment-only edits
record zero codegen invalidation. The index records these decisions but does not
yet substitute cached machine-code bytes into the foreground linker.
the daemon accepts them only for matching content and otherwise launches a
stable-source foreground-equivalent check. Uncertain dependents remain
conservative rather than under-invalidated. Adaptive/deep runs use hard
deterministic budgets and accept only proven manifest facts; deep mode is not a
completed superoptimizer, profile-guided tuner, or benchmarking engine.
# Incremental declaration records

Light mode has a versioned, checksummed `zagd-incremental-v1` advisory record
for each analyzed file. It stores content and parse fingerprints plus explicit
declaration-to-signature/type, layout, function body, caller, and codegen-region
fingerprints. An unchanged parse fingerprint can reuse parsed facts. Private
body changes invalidate functions, callers, and codegen regions; public shape
or layout changes invalidate all dependent layers. Root-profile, target, unknown,
truncated, corrupt, or executable-authority records conservatively invalidate
everything. These records never authorize executable reuse or source changes.
The daemon transactionally updates `incremental.record` after each stable file
snapshot, validates its content and target/root keys on restart, exposes reuse
and invalidation in `.zagd.status`, and includes it in cache-budget eviction.
Corruption is reported as `incremental_cache_reused=false` with unknown
invalidation; foreground compilation remains independent of the record.

## Deep finalist execution audit

`zagd_benchmark.zag` now contains a dedicated Linux x86-64 finalist executor.
It calls `execve` on the reviewed executable path directly (never `/bin/sh`),
places the child in a separate process group, applies `RLIMIT_CPU` and
`RLIMIT_AS`, observes a monotonic deadline and cancellation flag, caps stdout
and stderr independently, kills the process group on failure, and always reaps
the child. Its witness records stdout, stderr, normal exit status or terminating
signal, state, and elapsed monotonic time separately.

Execution remains fail closed unless the request is explicit deep mode, has at
most three finalists and bounded time/memory, matches the current stable source
and target hashes, and declares no network, GPU, or source mutation. After both
executions, measured persistence requires an exact comparison of the actual
stdout, stderr, exit, signal, and success-state witnesses; a caller-supplied
boolean is not accepted as equivalence. This is a resource supervisor for compiler-produced,
reviewed finalists, not a sandbox for hostile executables: the no-network/GPU/
mutation rule is planner authority enforced before execution, not a Linux
seccomp claim. Only equivalent output witnesses may become measured plan facts.

The daemon integration uses `.zagd.deep-reference` and `.zagd.deep-finalist` as
the explicit execution checkpoint. For one stable source/target candidate it
runs three bounded reference/finalist pairs, checks the semantic source hash
before and between executions, observes the stop file between runs, and
transactionally persists a measured record only after exact witness equality
for every pair. A stale, cancelled, mismatched, timed-out, or overflowing run
removes any prior measurement and publishes no replacement. These control files
authorize only compiler-produced reviewed executables; they add no filesystem
namespace, seccomp, network isolation, or hostile-code sandbox.
