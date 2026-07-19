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
work, budgets and cache health. `suggest` emits snapshot-bound advisory facts in
text or JSON. Shutdown is explicit and graceful. The transport is local-only,
versioned, project-scoped and must authenticate filesystem ownership before any
state-changing control message.

## Planner layers

Planning proceeds through exact constraints, deterministic validated patterns,
bounded candidate generation/pruning, a target-qualified cost model, then
optional finalist benchmarks. Correctness/effects/features/memory constraints
are hard filters. Expected runtime is the default objective, but a faster plan
is rejected when it exceeds memory or stability limits. Random exploration is
not a default policy.

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
the daemon accepts them only for matching content and otherwise launches a
stable-source foreground-equivalent check. Uncertain dependents remain
conservative rather than under-invalidated. Adaptive/deep runs use hard
deterministic budgets and accept only proven manifest facts; deep mode is not a
completed superoptimizer, profile-guided tuner, or benchmarking engine.
