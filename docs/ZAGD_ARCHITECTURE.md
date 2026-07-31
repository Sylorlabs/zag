# `zagd` architecture

Status: Linux light-mode implementation with bounded advisory-planner
foundations, 2026-07-24. Recursive inotify watching, stable content hashing,
transactional advisory snapshots, restart validation, status, suggestion,
shutdown, source-command auto-start, semantic declaration/caller/layout
identities, and conservative invalidation are implemented. General
language-wide dependency precision and automatic broad deep search are not.

## Purpose and correctness boundary

`zagd` is an automatically started, correctness-independent project-level
analysis and planning service driven by filesystem state. Editors are not part
of the protocol. A foreground `znc` build always remains authoritative and works
when the daemon is absent, stopped, stale, or has a corrupt cache.

The daemon never rewrites source. Regular Zag receives facts and suggestions.
Zag Script currently applies only the documented allocator policies, CPU,
device, and compiler-owned-layout defaults selected directly from configuration
when the corresponding CLI choice is unspecified. Foreground compilation does not consume
daemon candidate or deep-measurement records; doing so remains blocked until a
real transformation and end-to-end equivalence revalidation exist.

## Persistent user-service boundary

`tools/zagd-user-service.sh` can install a project-specific Linux systemd user
service for availability across login and unexpected daemon exits. It is not a
correctness dependency and never grants planner output foreground authority.
The generated unit runs the checked-in launcher rather than embedding a shell
command. Its executable, source path, and working directory are systemd
byte-escaped; untrusted path characters therefore cannot add unit directives or
extra command arguments.

The launcher transfers singleton ownership rather than assuming an empty
project. Public install/reload/restart commands stop any prior unit, request the
normal bounded `zagd --mode off` shutdown for a compiler-auto-started owner, and
require the lock to disappear before starting systemd. The private service
runner repeats the handoff before entering the watcher, covering an auto-start
that races the public command. Failure is reported without starting a competing
daemon; the generated unit also bounds its own stop interval to five seconds.

The launcher rereads the relevant project `.zagd.conf` values on every service
start. `restart` applies mode/window/cache/notification changes without
reinstalling. `reload` regenerates the private unit before restart when
`max_memory_bytes` changes so the daemon's address-space limit and systemd
`MemoryMax` stay equal. `mode=off` exits with an explicit no-restart status,
preventing a background CPU restart loop. The service remains low priority,
swap-disabled, and bounded; it uses no network or GPU.

## Watcher and stable reads

A target-neutral watcher interface exposes create, modify, delete, rename and
overflow/rescan events. Linux uses inotify where practical. Events are hints,
not source identity. After an event, the service applies a short configurable
stability window, reads the complete candidate, hashes its contents, compares
the previous hash, and publishes a snapshot only from the observed content.

Atomic rename saves, deletion/recreation and rapid patch sequences coalesce by
path and content. Identical rewrites produce no semantic invalidation. Event
queue overflow triggers a bounded project rescan. Temporary files, build output
and the daemon cache are ignored by explicit rules. An overflow first cancels
and invalidates advisory analysis, then publishes only after two complete,
bounded project scans have identical path/content sets. An exhausted stability
retry leaves the prior snapshot in place with `state=stabilizing`; it never
publishes the last half-written observation. Supervisors and tests may request
the identical recovery path by creating `.zagd.rescan`.

The safe symlink policy is deliberately simpler than target tracking:
project-internal file and directory symlinks are not followed, hashed, or
watched. Replacing a previously tracked regular source with a symlink removes
that source identity. The selected project root must itself be a real directory.
This prevents a project from redirecting the quiet daemon outside its root;
following selected symlinks may be added later only with explicit configuration
and target identity in the snapshot.

## Snapshot model

Each immutable `zagd-snapshot-v2` record names whether a root is selected, its
canonical project-relative module path and raw source-content hash, the project
root identity, canonical project-relative file paths and hashes, validity, full
parent identity, compiler version, planner mode, and target profile. When the
foreground manifest is current and complete for that same root, the record also
binds its semantic-graph identity and marks it complete; otherwise it stores the
empty graph identity with `semantic_graph_complete=0` rather than inventing
edges.

The manifest still publishes raw module hashes for freshness validation, but
does not fold those raw bytes into semantic-graph identity. That identity uses
canonical declaration identities, semantic edges, module names, and import
topology. An old record therefore fails current-file validation immediately
after a comment-only edit; after foreground republication, the raw source hash
changes while semantic graph and artifact/codegen identity remain stable.

The snapshot content identifier combines project-root, selected-root-module,
root-source, complete semantic-graph, and sorted file identities. The Linux
monotonic publication timestamp is explicit observability metadata and the
record states `timestamp_in_identity=false`; time never changes a content key.
The complete record is checksum-bound. Restart reuse additionally recomputes the
current root/source/graph binding and the complete snapshot identity from
reread file contents. Version-1, duplicate-field, unsafe-path, truncated,
trailing, stale-root, stale-graph, compiler, target, or mode mismatches are
ordinary cache misses.

Parsing may report transient invalid states. Medium and deep work runs only on a
stable, semantically valid snapshot. A newer snapshot cancels obsolete work.
There is no separate `znc checkpoint` command in this release. Adding one later
would only request consideration of the current stable content; it must never
become a correctness requirement.

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
`adaptive` and `deep` publish a bounded, inspectable set of allocation,
buffer-reuse, layout, CPU-region, and GPU-region alternatives after stability.
The foreground compiler now proves one deliberately narrow lifetime case from
the parsed AST: two statement-ordered local `[]f32`/`[]i32` raw-word
allocations with bounded constant sizes, exactly one matching direct free each,
and no shadowing, alias, escape, whole-buffer call exposure, control-flow
crossing, or use after free. The manifest records each pair's exact Linux
x86-64 byte capacities with `proven-foreground-ast` provenance. This supports a
human review suggestion only (`automatic=false`, `source_changes=false`,
`executable_authority=false`). The buffer-reuse executable candidate remains
rejected because no source/IR transform and end-to-end equivalence
revalidation exist. Analysis is capped at 64 candidate buffers per function
and emits only adjacent valid reuse-chain pairs, keeping work and manifest
growth linear; exceeding the cap emits no facts for that function. All broader
lifetime cases and the other transformation families remain unsupported.
There is one intentionally narrower supported Script candidate: if the root is
Script and the project CPU default resolves to the daemon's exact target key,
ZagD reports the existing
compiler-applied `script-default-cpu` decision. It has zero planner setup,
runtime, and memory cost; it is not a rewrite, a benchmark result, or a claim
of faster code. Its validity explicitly requires no foreground `--cpu`
override; a target mismatch is rejected rather than guessed. `deep` is
explicit and has a larger but still hard analysis budget. It can run explicitly
supplied, reviewed finalist executables under the bounded witness protocol
below, but does not perform broad plan search, PGO, SIMD tuning, or kernel
tuning. Invalidated work transitions immediately to cancelled and its result
cannot be published.

### Validated profile evidence

Deep mode can read a bounded `.zagd.profile` only when its checksum and exact
daemon-executable, semantic-plan, and CPU-target keys match. Its
`zagd-profile-plan-v3` output additionally records the current compiler
version, exact sibling foreground-compiler image identity, semantic source
hash, complete semantic-graph hash, target cache key, profile payload identity,
deterministic hot counts, and a checksum over the plan record itself. Every hot
label must exactly match a current `decl_fn` semantic-manifest declaration.
Missing declarations, unavailable features, unknown labels, and
`simd-packed` are retained only as deterministic rejected advisory rows with a
reason.

An eligible `popcount` or `andn` row means only that generic-target profile
evidence has been validated. The foreground compiler automatically consumes
that metadata only after the exact parsed module contents, compiler image,
semantic source and graph, target, semantic-plan identity, row count, and
checksum all match. A hit has `codegen_effect=none`: it does not change
lowering, optimization passes, machine-cache keys, emitted bytes, source, or
target selection. `--profile-report` exposes hit/miss provenance and
`--no-zagd-profile` disables the read. `znc suggest` still marks the evidence
unsupported and non-automatic because there is no exact
declaration-to-machine-region map. This is a production fail-closed metadata
consumer, not implemented PGO code generation, auto-vectorization, or GPU
placement.

The service states are starting, idle, stabilizing, analyzing-light,
analyzing-adaptive, analyzing-deep, cancelling, recovering and stopped. At most
one snapshot is current; results name their snapshot and validity conditions.
The event loop remains blocking while idle. A stop file created in the narrow
interval after singleton publication but before inotify setup is checked once
before the first blocking read, so immediate shutdown is deterministic without
introducing polling.

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
search, advisory notifications, bounded memory and disk cache, and prompt
cancellation. Projects may opt down to `notifications=errors_only`; normal Zag
gets one unobtrusive warning only when a supported human-review suggestion
exists. Rejected or unsupported planner scaffolding remains silent. The event
loop blocks in the kernel when idle, so idle CPU should approach zero.
Foreground builds and tests take priority. Cache eviction is content-record
eviction, never source deletion.

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
and every module-node content hash before emitting deterministic text or JSON.
Constant-return and effect-free-leaf facts are reported as unsupported planner
transformations with explicit rejection reasons. Allocation-effect review and
explicit-type review are supported human advisories; allocation effects alone
do not infer lifetime, byte size, buffer non-overlap, or performance benefit.
The separate `proven-buffer-lifetimes` item is supported only for the narrow
AST proof above and reports the largest exact shared pair capacity without
claiming a realized saving. Every JSON item
states `supported`, `automatic`, confidence, evidence basis, evidence, action,
validity, and rejection reason. Regular Zag always remains `automatic=false`
and `source_changes=false`; Script allocator/CPU/device/layout defaults are
automatic only where the corresponding structured CLI choice is absent and the
configured value is implemented.
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

Adaptive/deep mode records a fixed, bounded set of buffer-reuse,
arena-temporary, compiler-owned-layout, CPU-chunk, and GPU-region alternatives.
The current semantic manifest proves allocation effects and the narrow local
raw-buffer lifetime case above, but does not prove general allocator-body
lifetimes, loop parallelism, device equivalence, or layout/ABI equivalence.
Those five executable transformation alternatives therefore remain
`supported=0`, `equivalent=0`, `automatic=0`, have unknown transformation
costs, and carry an explicit rejection reason. When exact local facts exist,
`zagd-candidates-v2` also records their pair count, maximum shared capacity,
validity, and provenance separately from the rejected executable candidate.

For a Script root only, `zagd-candidates-v2` may add a sixth family,
`script-default-cpu` (kind 51). It is emitted only when the configured CPU
profile and active daemon target have the same feature-qualified cache key; its
validity also requires that the later foreground command has no explicit
`--cpu`. The candidate is `supported=1`, `equivalent=1`, `automatic=1`, with
`derived` provenance and zero planner cost because `znc` already validates and
applies this default before lowering. The daemon record remains advisory and
`source_changes=false`; it never changes a command, source, machine code, or
foreground cache decision. Any target mismatch, explicit command choice, stale
module, or invalid configuration fails closed. Its identity combines the
canonical semantic declaration/effect/layout facts, module-graph topology,
compiler version, and active CPU cache key.

Deep measurements are accepted only for three explicitly supplied bounded runs
and exact whole-semantic/module-graph plus active-CPU target identities. Every
module hash is reread before and between finalist executions. Stale, malformed,
cancelled, non-deep, target-mismatched, or witness-mismatched measurements are
ignored and any prior record is removed. The record explicitly states
`foreground_consumption=false`; timings never authorize source rewrites or
bypass foreground compilation.

Profile ingestion uses the bounded `zagd-profile-v1` record. A record is
accepted only when its checksum and exact compiler-binary, semantic-source and
target hashes match the current planning request. Hot-region samples are
positive counters with canonical region names; selection is capped by a hard
budget, sorted by descending count and then lexical name, and contains no
random tie breaking. Stale, corrupt, oversized and mismatched profiles are
ignored.

Profile-backed backend records currently select only the optional instructions
the native backend already implements and differentially tests: POPCNT and
BMI1 ANDN, and only when the resolved target feature set permits them. A packed
SIMD request is recorded as unsupported and never selected: the bounded SSE2
`i32x4` intrinsic is not a general profile-selectable SIMD contract. GPU and
kernel tuning are not profile candidates in this release.

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

The lexical index is not a semantic dependency graph and is never used to
invent one. The foreground compiler now publishes checksum-bound AST/resolver
facts for module/import nodes, exact declaration origins, declaration-to-type
and layout edges, function-call edges, codegen regions, and an advisory
whole-program machine-cache link. The incremental index is bound to that graph
identity and cannot be reused for localized dependency work unless both the
saved and current manifests mark the graph complete. A missing origin, malformed
edge, stale checksum, or incomplete manifest fails closed to broad invalidation;
the daemon does not recover edges by re-scanning text.

The foreground compiler remains the executable-cache authority. The machine
link is identity/accounting only: it contains no payload and may not skip a
foreground validation, code generation, or link step.

Large merged units publish `detail_level=compact` instead of an incomplete
memory-ceiling summary. Compact mode omits verbose expression/value/copy and
local buffer-lifetime witnesses, but retains exact public/effect/layout
identities, declaration identities, call/type/layout/import/module topology,
raw module hashes for freshness, `graph_complete`, and the final record
checksum. Consumers label omitted witness families unavailable and may not turn
their absence into a negative proof or recommendation.

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
record zero codegen invalidation. The daemon index never authorizes executable
reuse. Independently, the foreground compiler consumes a v4 whole-program cache
before backend lowering only after exact compiler image/version, project root,
source label, comment-insensitive root/import token identities, freshly
revalidated complete semantic graph, target/CPU features, ABI/pipeline, resolved
strict/Script policy, lengths, and record/code/data checksums. Reads reject
symlink or non-regular final components, oversized files, duplicate/trailing
record fields, partial triplets, and directory symlinks. Unique `O_EXCL`
temporaries publish payloads first and the authoritative record last, so
concurrent or interrupted publication is only a miss. A hit substitutes the
validated encoded code/data with zero lowering calls; static linking, debug
patching, hot metadata, and ELF output remain fresh. Any mismatch falls back to
one ordinary lowering. The daemon's `max_cache_bytes` accounting uses file
metadata rather than reading payloads and includes the foreground
`machine.record`, `machine.code`, and `machine.data` triplet; an over-budget
triplet is evicted as a unit.

The daemon accepts advisory semantic facts only for matching content and
otherwise launches a stable-source foreground-equivalent check. Uncertain
dependents remain
conservative rather than under-invalidated. Adaptive/deep runs use hard
deterministic budgets and accept only proven manifest facts; deep mode is not a
completed superoptimizer, profile-guided tuner, or benchmarking engine.

## Incremental declaration records

Light mode has a versioned, checksummed `zagd-incremental-index-v2` advisory
project index containing one record for each analyzed file. It stores content
and parse fingerprints plus explicit declaration-to-signature/type, layout,
function body, caller, and codegen-region fingerprints. An unchanged parse
fingerprint can reuse parsed facts. Private body changes invalidate functions,
callers, and codegen regions; public shape or layout changes invalidate all
dependent layers. Root-profile, target, unknown, truncated, corrupt, or
executable-authority records conservatively invalidate everything. These
records never authorize executable reuse or source changes.

The daemon transactionally updates the complete `incremental.record` index
after each stable file snapshot, validates each reusable entry's content and
target/root keys plus the current complete semantic-graph identity on restart,
exposes reuse and invalidation in `.zagd.status`, and includes it in cache-budget
eviction. An incomplete graph is retained for diagnostics but cannot produce a
localized reuse claim.
Corruption is reported as `incremental_cache_reused=false` with unknown
invalidation; foreground compilation remains independent of the record.

On a missing, corrupt, source-stale, or mode-incompatible snapshot, the
singleton owner performs a bounded two-read source-tree scan before publishing
its initial idle status. The stable result becomes the replacement snapshot and
incremental baseline; an unstable result remains a cache miss. Cache rebuilding,
candidate publication, and eviction occur only after singleton acquisition, so
a losing concurrent starter cannot modify the active daemon's advisory state.

## Deep finalist execution audit

`zagd_benchmark.zag` now contains a dedicated Linux x86-64 finalist executor.
It calls `execve` on the reviewed executable path directly (never `/bin/sh`),
places the child in a separate process group, applies `RLIMIT_CPU` and
`RLIMIT_AS`, observes a monotonic deadline and cancellation flag, caps stdout
and stderr independently, kills the process group on failure, and always reaps
the child. Its witness records stdout, stderr, normal exit status or terminating
signal, state, and elapsed monotonic time separately.

Execution remains fail closed unless the request is explicit deep mode, has at
most three finalists and bounded time/memory, matches the current complete
semantic/module-graph and active-CPU target identities, and declares no network,
GPU, or source mutation. After both executions, measured persistence requires an
exact comparison of the actual
stdout, stderr, exit, signal, and success-state witnesses; a caller-supplied
boolean is not accepted as equivalence. This is a resource supervisor for compiler-produced,
reviewed finalists, not a sandbox for hostile executables: the no-network/GPU/
mutation rule is planner authority enforced before execution, not a Linux
seccomp claim. Only equivalent output witnesses may become measured plan facts.

The daemon integration uses `.zagd.deep-reference` and `.zagd.deep-finalist` as
the explicit execution checkpoint. For one stable semantic/module-graph and
active-CPU identity it runs three bounded reference/finalist pairs, rereads all
module hashes before and between executions, observes the stop file between
runs, and transactionally persists a measured record only after exact witness
equality for every pair. A root or imported-module change, cancellation,
mismatch, timeout, or output overflow removes any prior measurement and
publishes no replacement. These control files authorize only compiler-produced
reviewed executables; they add no filesystem namespace, seccomp, network
isolation, or hostile-code sandbox.
