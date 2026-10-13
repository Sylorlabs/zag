# Native evidence: closures, build receipts, and callback replay

The current source provides parser-backed source closures, opt-in receipts for
a bounded native build path, and native callback replay with hash-chained
execution transcripts. `znc` is the supported compiler name. `zagc` is retired;
there is no new compatibility alias.

This guide describes the implemented CLI and APIs, not global build support or
all-target parity. The release and target contract remains
[SUPPORT.md](SUPPORT.md). Verification status for this work is recorded below.

## Pins and trust

A SHA-256 pin checks **integrity, not authentication**. Keep the expected digest
independently of the bytes being verified. Hashing an untrusted record and then
verifying it against that new hash establishes only internal consistency.
Neither hashes nor custody labels prove an actor's identity, a trusted compiler
publisher, an actual transfer, or that arbitrary supplied bytes were executed.
These APIs contain no signature or credential authority.

Two spellings are deliberately different:

- Manifest `[toolchain] compiler` and the pinned source-closure API use
  `sha256:<64 lowercase hexadecimal digits>`.
- CLI `--compiler-pin`, CLI evidence `--pin`, and evidence API digest parameters
  use the **bare 64 lowercase hexadecimal digits** (called `SHA64` below).

Manifest toolchain pins are optional. Build evidence always requires an
independently supplied CLI compiler pin, including for standalone sources and
projects with no manifest pins.

## Inspect the actual source closure

Set `ZNC` to the selected current compiler executable, then run:

```sh
"$ZNC" --emit-closure src/main.zag --output source-closure.manifest
"$ZNC" emit-closure src/main.zag
```

`--output` (or `-o`) requires a new path; omitting it prints to stdout. The
current format is `zag-source-closure-v1`. It binds exact parser-retained source
and resource snapshots with SHA-256 and byte counts, records explicit resolved
import edges, and adds recursive manifest snapshots, package edges, and optional
toolchain pins. Supplemental manifests must agree with same-path retained
snapshots. Closure inspection records pins; it does not enforce compiler
identity. Build evidence uses the pinned API instead.

See [Parser-backed source closure](LOCAL_PACKAGE_IMPORTS.md#parser-backed-source-closure)
for record fields, normalization, limits, and the `source_closure_from_unit`,
`source_closure_from_unit_pinned`, and `source_closure_load` APIs. This is a
snapshot of parser inputs and manifest requirements, not runtime file-access
instrumentation or a source-content archive. Absolute lexical paths make the
closure location-bound, and ordinary symlink semantics apply.

## Create a native build receipt

Use a strict Zag source and fresh artifact/receipt paths. Create the content
store directory before invoking the compiler. In this example, set
`COMPILER_SHA64` to the independently selected compiler digest and `TARGET` to
one of the CLI targets in the table:

```sh
mkdir -p evidence/store
"$ZNC" build src/main.zag -o evidence/app \
  --target "$TARGET" \
  --build-receipt evidence/build.ev \
  --compiler-pin "$COMPILER_SHA64" \
  --content-store evidence/store \
  --no-zagd --no-foreground-cache --no-analyze
```

Source-first `"$ZNC" src/main.zag ...` also works. The actual interface is
`--build-receipt <new-path> --compiler-pin <SHA64> --content-store <existing-dir>`.
Supplying `--compiler-pin` or `--content-store` without `--build-receipt` rejects.
The driver checks the current compiler image before building and checks it again
when capturing evidence. Every compiler pin declared in the recorded manifest
snapshots must match that same image.

| CLI target | Target string in receipt/input envelope |
|---|---|
| `x86-64` | `linux-x86_64` |
| `arm64` | `linux-arm64` |
| `macos-arm64` | `macos-arm64` |

These are the driver's accepted evidence targets, not proof that this work has
been run on every target. Evidence mode covers **strict, unlinked native
executables only**: no external library inputs or custom link options; macOS
external dynamic imports are also refused. Script-profile input rejects even
without an explicit `--script` flag. Evidence builds bypass foreground machine
cache reuse and automatic daemon startup.

### Closed option set

The evidence preflight accepts only the build/source command plus:

- Paired options: `--build-receipt`, `--compiler-pin`, `--content-store`, `-o`,
  and `--target`.
- Switches: `--no-zagd`, `--no-foreground-cache`, `--no-analyze`,
  `--safety=checked`, and `--sanitize=memory`.

Other options reject rather than silently producing incomplete evidence. This
includes `--debug`, `--dynamic`, `--emit-obj`, `--emit-static`, dylib/shared
output, `--hot`, `--script`, `--emit-closure`, CPU/vectorization controls, and
link flags. Use the separate-value spellings above, not `--target=...` or a
`--output` alias. Paired options cannot repeat, and their values cannot start
with `-`; prefix such paths with `./`. Receipt mode is not an option for
commands such as `init`, `status`, or `watch`.

### Files and publication semantics

For the example above, a successful invocation creates:

| Path | Contents |
|---|---|
| `evidence/app` | Final native executable image from the artifact writer |
| `evidence/build.ev.inputs` | `zag-native-build-inputs-v1` envelope |
| `evidence/build.ev.provenance` | `zag-artifact-provenance-v1` record |
| `evidence/build.ev` | `zag-content-build-v2` receipt; completion marker |
| `evidence/store/<artifact-SHA64>` | Exact artifact bytes, named by their SHA-256 digest |

The input envelope binds the target, closure text, project `.zagd.conf` path
and presence/raw contents, and exact invocation arguments excluding argv[0].
It is more than the root source hash. Invocation/output paths and absolute
closure paths affect this evidence, so it is not a relocation-independent or
hermetic rebuild key. The CAS stores artifact bytes, not every source file.

Provenance identifies generator `znc` and its compiler-image hash, one
`compiler-input-snapshot` input, and a `znc` to `content-store` custody step with
action `native-build`. Both the input and artifact classification are
**`synthetic`**: there is no prior authenticated source custody. The input's
content and provenance digest slots both reference the input-envelope hash;
this is not a recursively authenticated input-provenance chain. A generic
`sealed` classification in the provenance API is producer-declared, not a
signature or proof of origin.

Artifact and evidence files are create-only through exclusive creation; an
existing artifact path, including a symlink or hard-link alias, is refused
without truncation. Normalized artifact paths conflicting with the receipt or
either sidecar reject. The artifact is created first (requested mode `0755`,
subject to umask); evidence/CAS files request `0600`. A preexisting CAS object
is reused only if its bytes equal the emitted artifact. Conflicting bytes under
the digest filename cause refusal and are preserved.

The receipt is published last. Publication is not a multi-file transaction:
failure can leave an artifact, CAS object, or partial sidecars. A nonzero exit
means the build was not successfully receipted; choose fresh paths for another
attempt. Success prints `znc evidence: receipt-sha256=...` and
`znc evidence: artifact-sha256=...`. Preserve the receipt digest independently
for later verification.

## Verify records and artifact bytes

Set `RECEIPT_SHA64` to the independently retained receipt digest. The generic
CLI hook is:

```sh
"$ZNC" evidence evidence/build.ev --pin "$RECEIPT_SHA64"
```

It checks the external record pin and canonical `ZAGEV1` framing/checksum only.
Its success message is `evidence: pinned framing verified (not execution
authentication)`. It does not run schema-specific receipt verification, inspect
the artifact/CAS bytes, replay callbacks, or authenticate execution.

Use `selfhost/content_addressed_build.zag` for receipt semantics:

```zag
fn content_build_receipt_encode(source: []u8, compiler: []u8, target: []u8,
    artifact: []u8, provenance: []u8, expected_compiler_sha: []u8) []u8

fn content_build_receipt_verify(text: []u8, pin: []u8,
    inputs: BuildReceiptInputs, expected_compiler_sha: []u8) i32
```

`BuildReceiptInputs` has `source`, `compiler`, `target`, `artifact`, and
`provenance` byte-slice fields. For a CLI receipt, `source` means the entire
`.inputs` envelope, `compiler` is the compiler image, and `provenance` is the
`.provenance` file. Supply the exact target string from the table and actual
artifact bytes. Verification checks the independently expected compiler hash,
input/artifact/provenance hashes, artifact length, and content address. The
content address binds input hash, compiler hash, target, and artifact hash; the
CAS filename is the artifact hash, not this composite address. v1 receipts are
not accepted as v2.

Receipt verification binds provenance bytes but does not validate their schema.
Use `artifact_provenance_verify(text, pin, artifact, generator_image)` from
`selfhost/artifact_provenance.zag` for that check. Read and verify the CAS object
as actual bytes too; its filename alone proves nothing. The integration example
in `tests/native_evidence_verify.zag` checks the receipt, input envelope,
synthetic provenance, output artifact, and stored artifact separately.

The standalone encode API binds supplied bytes; the caller must ensure the
claimed compiler actually built the artifact. The native driver supplies this
connection for the bounded build path above. Encoders return an owned empty
string on refusal; verifier return value `1` means success. Free returned
strings with `_zag_str_free`, and decoded `EvidenceRecord.fields` with
`ev_fields_free`. The shared codec limits an encoded record to 1 MiB and 8,192
fields; hex encoding and nested envelopes count toward that bound. Separate
64 MiB input/artifact hash limits do not override the record-size limit.

## Run hostile cases through native callbacks

`selfhost/hostile_replay.zag` executes trusted in-process Zag callbacks against
a pinned corpus. Mutants are caller-supplied input cases, not executable code
or an automatic mutation generator. The API is:

```zag
struct ReplayCase {
    name: []u8, input: []u8, expected: []u8, parent: []u8, mutation: []u8
}

fn hostile_replay_encode(compiler: []u8, cases: ArrayList[ReplayCase]) []u8
fn hostile_replay_verify(text: []u8, pin: []u8, compiler: []u8) i32
fn hostile_replay_run(text: []u8, pin: []u8, compiler: []u8,
    expected_compiler_sha: []u8, module_context: []u8,
    callback: fn([]u8, *ArrayList[u8]) i32) ReplayResult
```

Build an adapter that appends the tested operation's actual observation to the
runner-owned output buffer and returns `0` on completion, nonzero on callback
failure. The input is a private copy; the callback may not free or retain input
or output buffers. `module_context` is a nonempty adapter-supplied description
of the tested module/configuration, hashed into the transcript; it does not
authenticate or automatically identify the callback's code.

The corpus accepts 1–256 cases, including empty/binary inputs and expected
outputs. Names are unique and mutation labels nonempty. A mutant's nonempty
`parent` names an earlier case, and its input must differ from that parent's.
All corpus structure, hashes, and compiler identity checks finish before any
callback runs. `hostile_replay_verify` validates the corpus without running it.

`ReplayResult` distinguishes completion from success:

- `valid=1`: all calls completed and a complete transcript was encoded.
- `passed=1`: additionally, all actual observations matched expectations.
- `executed`, `mismatches`, `mutants`, and `mutant_mismatches` count actual calls
  and comparisons. Ordinary mismatches do not stop subsequent cases.
- `survivors` counts mutants whose actual observation equals the parent's actual
  observation despite differing expectations. This is distinct from the total
  mutant mismatch count, especially when the parent also fails.
- `transcript` is owned. Callback failure or oversized observations yield
  `valid=0`, preserve the number of calls already made, and publish no partial
  transcript. Release the result with `hostile_replay_result_free`.

See `tests/fixtures/evidence_replay_callbacks.zag` and
`selfhost/evidence_codec_test.zag` for real callbacks: the guard accepts
`normal` and rejects `evil`; its regression accepts both, producing a mutant
mismatch and survivor in the actual-call transcript.

## Record and verify execution transcripts

`selfhost/execution_transcript.zag` exposes:

```zag
fn execution_record_begin(compiler_image: []u8, input: []u8,
    context: []u8) ExecutionRecorder
fn execution_record_event(rec: *ExecutionRecorder, event: ExecutionEvent) i32
fn execution_record_finish(rec: *ExecutionRecorder, status: i32) []u8
fn execution_transcript_verify(text: []u8, pin: []u8, compiler: []u8,
    input: []u8, context: []u8) i32
```

`ExecutionEvent` contains `operation`, `request`, `response`, and `status`.
The recorder hashes compiler/input/context identities into a genesis link,
then chains each event's index, operation, request, response, and status. It
accepts at most 256 events and statuses from 0 to 255, with a mandatory final
count and terminal status. Keep an external SHA64 pin for the **whole returned
transcript** to detect suffix deletion even if an altered chain is rehashed.
Free the finished text and `rec.fields` when done.

Replay supplies real callback observations: operation is the case name,
request is the recorded input, response is actual output, and event status is
`0` for match or `1` for mismatch. Terminal status is `1` iff there were
mismatches. The transcript input hash binds the entire corpus, including
expectations and mutant relationships. Verify against that corpus and the same
compiler/context bytes. A valid transcript may faithfully record failed cases;
verification alone does not mean the replay passed.

The general recorder records events supplied by a runtime adapter. It is **not
full automatic runtime instrumentation**: it does not launch a process or
automatically intercept syscalls, file/network access, nondeterminism, or every
operation of an arbitrary executable. Replay does not provide timeout/crash
containment or an OS sandbox for callbacks, and these APIs establish no
all-target runtime parity.

## Process supervision and isolation requirements

`selfhost/std/process_platform.zag` exposes typed supervision capabilities
(platform, process groups, nonblocking observation, deadline waits, fail-closed
behavior, and isolation). Process groups and deadlines are supervision, not a
security sandbox.

`process_platform_check_isolation(ProcessIsolationRequirement.SupervisionOnly)`
returns `accepted=1`, `sandboxed=0`, status `NotRequested`.
`ProcessIsolationRequirement.SecuritySandbox` returns `accepted=0`,
`sandboxed=0`, status `Unsupported`, even if a capability bit claims isolation.
Neither backend installs a kernel sandbox through this API.

`process_run_bounded_with_isolation(command, timeout_ms, max_output, requirement)`
in `selfhost/std/process.zag` checks this decision **before pipe creation or
fork**. A sandbox requirement returns process status `-1` and
`process_state_isolation_unsupported()` (state `4`), without starting a child.
The ordinary `process_run_bounded` path requests supervision only.

## Verification status

Final focused verification on 2026-10-13, using a native macOS ARM64 compiler
built from the edited source. The workspace executable is `build/znc-evidence`
(from the repository root: `zag-poc/build/znc-evidence`), byte-identical to the
verified fixed-point image. No tracked seed was replaced by this work.

| Check | Observed result |
|---|---|
| Native build-evidence integration (`tests/run_native_evidence.sh`) | PASS, including alias/dispatch/tamper regressions |
| Evidence API suite (`tests/run_evidence_codec.sh`) | `evidence-codec checks=39 fail=0` |
| Source closure tests (`tests/run_source_closure.sh`) | PASS, including 7 pinned-snapshot and 13 source-unit checks |
| Package resolution (`tests/run_package_resolution.sh`) | `pass=42 fail=0` |
| Toolchain identity shell gate | PASS; real CLI pin rejection also exercised in native integration |
| Final reviewed bootstrap | PASS; stage2 and stage3 byte-identical, daemon also built |
| Process platform (`tests/run_process_platform.sh`) | PASS on native macOS ARM64, Docker Linux ARM64, emulated Linux x86-64 |
| Script low-memory process boundary | PASS, including result-header exhaustion |
| macOS filesystem/executable identity ABI | PASS, including restricted exclusive-create modes |
| Derivation ledger regression | `pass=14 fail=0` |
| Pure-Zag tree check | PASS; no added foreign implementation dependencies |
| Receipt cross-target checks | Linux ARM64, emulated Linux x86-64, native macOS ARM64 executables ran; receipts verified; ordinary/evidence writer bytes identical |

Independent source review confirmed resolution of five integration findings:
compiler-owned output identity, exclusive publication/alias safety, enforcement
of the exact recorded manifest pins, flag-shaped argument rejection, and
non-build command refusal. The full release suite was not run. These focused
results do not establish release readiness or general platform parity.

To rerun the focused gates from `zag-poc`, select a current native compiler:

```sh
ZNC="$PWD/build/znc-evidence"
ZNC="$ZNC" bash tests/run_native_evidence.sh
ZNC="$ZNC" bash tests/run_evidence_codec.sh
ZNC="$ZNC" bash tests/run_source_closure.sh
ZNC="$ZNC" bash tests/run_package_resolution.sh
ZNC="$ZNC" bash tests/run_script_process_boundary.sh
ZNC="$ZNC" PROCESS_TEST_CLI="$ZNC" PROCESS_TEST_LINUX=1 bash tests/run_process_platform.sh
```

The native integration gate selects the host target, runs the emitted program,
and checks evidence with a native Zag verifier and an independent SHA oracle.
The evidence suite includes callback mutants, transcript tampering, wrong pins,
and failure paths; closure tests cover nested imports, retained resources,
manifest snapshots/pins, and rejection cases. Test definitions describe what
to exercise; only a recorded run establishes a result for a particular compiler
and host.
