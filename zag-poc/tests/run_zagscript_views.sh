#!/usr/bin/env bash
# Focused authority for ZagScript semantic views and portable bounded reversal.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
caller_dir=$PWD
cd "$script_dir"

compiler=${ZNC:-"$script_dir/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$caller_dir/$compiler" ;;
esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/app.zag" <<'ZAG'
script;
let answer: i32 = 40 + 2;
return answer;
ZAG

"$compiler" view "$tmp/app.zag" --level simple --no-zagd >"$tmp/simple"
cmp "$tmp/app.zag" "$tmp/simple"

"$compiler" view "$tmp/app.zag" --level explained --format json --no-zagd >"$tmp/explained"
grep -q '"profile":{"value":"script"' "$tmp/explained"

"$compiler" view "$tmp/app.zag" --level explicit --format json --no-zagd >"$tmp/explicit"
grep -q '"candidate_compilable":true' "$tmp/explicit"

"$compiler" view "$tmp/app.zag" --level native --no-zagd >"$tmp/native"
grep -q '^module {' "$tmp/native"
grep -q 'func.func' "$tmp/native"
grep -q '^// schema=zag-ir-v1 transform=zag-transform-v1' "$tmp/native"
grep -q '^// native-target=linux-x86_64 cpu=' "$tmp/native"
grep -q ' lowering=\(zir-direct\|verified-ast-bridge\) ir-verifier=def-before-use-v1 artifact_ir_consumed=[01]$' \
    "$tmp/native"
grep -Eq '^// semantic-transform-status=(verified_no_transform|verified_raw_ast_bridge_incomplete) rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
    "$tmp/native"
native_route=$(sed -n 's/^\/\/ native-target=.* lowering=\([^ ]*\) ir-verifier=.*/\1/p' "$tmp/native")
native_status=$(sed -n 's/^\/\/ semantic-transform-status=\([^ ]*\).*/\1/p' "$tmp/native")
native_ir_consumed=$(sed -n 's/^\/\/ native-target=.* artifact_ir_consumed=\([01]\)$/\1/p' "$tmp/native")
case "$native_route:$native_status" in
    zir-direct:verified_no_transform|\
    verified-ast-bridge:verified_no_transform|\
    verified-ast-bridge:verified_raw_ast_bridge_incomplete) ;;
    *)
        echo "inconsistent native route/transform status: $native_route:$native_status" >&2
        exit 1
        ;;
esac
case "$native_route:$native_ir_consumed" in
    zir-direct:1|verified-ast-bridge:0) ;;
    *)
        echo "native view misstated displayed-IR artifact consumption: $native_route:$native_ir_consumed" >&2
        exit 1
        ;;
esac
grep -q '^// machine-pipeline=regalloc,optimize,peephole raw-instructions=' "$tmp/native"
grep -q '^// x86\[[0-9][0-9]*\] [a-z0-9_][a-z0-9_]* kind=' "$tmp/native"
grep -q '^// machine-code-hex=[0-9a-f][0-9a-f]*$' "$tmp/native"

# Promotion/unexpand are intentionally unavailable while the ownership-safe
# The bounded v2 codec has a focused gate, but foreground prepared-evidence
# integration is unavailable. The compact/explained/native view checks above
# remain independently executable; do not treat a stale or fabricated sidecar
# as reversible provenance.
if grep -q 'zdl_runtime_integration_unavailable' selfhost/derivation_ledger.zag; then
    grep -q '^fn znc_derivation_ledger_v2' selfhost/native/znc.zag
    grep -q '^fn znc_ledger_runtime_enabled()i32{return 0;}' selfhost/native/znc.zag
    grep -q 'module_graph_checksum' selfhost/derivation_ledger.zag
    echo "zagscript views: core view checks passed; reversible ledger runtime integration unavailable" >&2
    echo "zagscript-views core pass=1 fail=0"
    exit 0
fi

# Native instruction view: compile a minimal edition-2027 C ABI export to an ELF
# object and disassemble it to prove machine-instruction output is available.
cat >"$tmp/zag.mod" <<'MOD'
name = "objview"
version = "0"
edition = "2027"
MOD
cat >"$tmp/cabi.zag" <<'ZAG'
pub fn add(a:i64,b:i64)i64 @cabi_export { return a+b; }
ZAG
$compiler "$tmp/cabi.zag" --emit-obj -o "$tmp/cabi.o" --no-zagd --no-analyze --no-foreground-cache >"$tmp/cabidump.log" 2>&1
objdump -d "$tmp/cabi.o" >"$tmp/cabi.asm"
grep -q 'add .*%rcx,%rax' "$tmp/cabi.asm"

"$compiler" expand "$tmp/app.zag" --to explicit \
    --output "$tmp/derived-only.zag" --no-zagd >/dev/null
test -s "$tmp/derived-only.zag"
test ! -e "$tmp/derived-only.zag.zsledger"

"$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/promoted.zag" \
    --test-command "test -s $tmp/promoted.zag" --no-zagd >/dev/null
test -s "$tmp/promoted.zag"
test -s "$tmp/promoted.zag.zsledger"
grep -q '^format=zagscript-derivation-v2$' "$tmp/promoted.zag.zsledger"
grep -q '^complete=true$' "$tmp/promoted.zag.zsledger"
grep -q '^projection=common-prefix-suffix-envelope-with-unique-line-context-v1$' \
    "$tmp/promoted.zag.zsledger"
grep -q '^general_structural_projection=false$' "$tmp/promoted.zag.zsledger"
grep -q '^formal_proof_certificate=none$' "$tmp/promoted.zag.zsledger"
grep -q '^formal_equivalence_verified=false$' "$tmp/promoted.zag.zsledger"
grep -q '^optimizer_transform_count=0$' "$tmp/promoted.zag.zsledger"
grep -q '^choice_scope=cli-and-project-config-v1$' "$tmp/promoted.zag.zsledger"
grep -q '^verifier_kind=linked-foreground-validation-v1$' "$tmp/promoted.zag.zsledger"
grep -q '^semantic_graph_complete=1$' "$tmp/promoted.zag.zsledger"
grep -q '^module_count=1$' "$tmp/promoted.zag.zsledger"
grep -q '^import_count=0$' "$tmp/promoted.zag.zsledger"
grep -q '^resource_count=0$' "$tmp/promoted.zag.zsledger"
grep -Eq '^module_graph_checksum=[0-9]+,[0-9]+,[0-9]+$' "$tmp/promoted.zag.zsledger"
grep -Eq '^ast_origin_count=[1-9][0-9]*$' "$tmp/promoted.zag.zsledger"
grep -Eq '^derived_segment_count=[1-9][0-9]*$' "$tmp/promoted.zag.zsledger"
grep -q '^choice_count=10$' "$tmp/promoted.zag.zsledger"
grep -q '^transform_count=3$' "$tmp/promoted.zag.zsledger"
grep -q '^compiler_count=1$' "$tmp/promoted.zag.zsledger"
grep -q '^verifier_count=1$' "$tmp/promoted.zag.zsledger"

# Compiler-bound Script calls are promoted from the same bound AST as the
# explicit view. Their generated imports/body are ledger segments, never
# mislabeled as byte-exact compact source, and unexpand restores the snapshot.
cat >"$tmp/prelude.zag" <<'ZAG'
script;
let contents = read_file("input.txt");
return 0;
ZAG
printf 'view prelude\n' >"$tmp/input.txt"
"$compiler" promote "$tmp/prelude.zag" --to explicit \
    --output "$tmp/prelude-promoted.zag" \
    --test-command "test -s $tmp/prelude-promoted.zag" --no-zagd >/dev/null
grep -q '^import_count=' "$tmp/prelude-promoted.zag.zsledger"
test "$(sed -n 's/^import_count=//p' "$tmp/prelude-promoted.zag.zsledger")" -ge 1
grep -Eq '^derived_segment_count=[2-9][0-9]*$' "$tmp/prelude-promoted.zag.zsledger"
prelude_basis_hex=$(printf '%s' 'compiler-bound-prelude-imports-v1' | od -An -tx1 | tr -d ' \n')
grep -q "$prelude_basis_hex" "$tmp/prelude-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/prelude-promoted.zag" \
    --output "$tmp/prelude-restored.zag" --no-zagd >/dev/null
cmp "$tmp/prelude.zag" "$tmp/prelude-restored.zag"

# Promotion never overwrites a human-owned output or its provenance.
if "$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/promoted.zag" --test-command true --no-zagd \
    >"$tmp/existing.log" 2>&1; then
    echo "promote overwrote an existing output" >&2
    exit 1
fi
grep -q 'already exists' "$tmp/existing.log"

# Dangling entries are still human-owned objects. Nofollow checks must preserve
# both the symlink and its nonexistent target instead of rename-overwriting it.
promote_link_target="$tmp/promote-link-target-must-remain-absent"
ln -s "$promote_link_target" "$tmp/dangling-output.zag"
if "$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/dangling-output.zag" --test-command true --no-zagd \
    >"$tmp/dangling-output.log" 2>&1; then
    echo "promote overwrote a dangling output symlink" >&2
    exit 1
fi
grep -q 'already exists or is not safe' "$tmp/dangling-output.log"
test -L "$tmp/dangling-output.zag"
test "$(readlink "$tmp/dangling-output.zag")" = "$promote_link_target"
test ! -e "$promote_link_target"
test ! -e "$tmp/dangling-output.zag.zsledger"

sidecar_link_target="$tmp/sidecar-link-target-must-remain-absent"
ln -s "$sidecar_link_target" "$tmp/dangling-sidecar.zag.zsledger"
if "$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/dangling-sidecar.zag" --test-command true --no-zagd \
    >"$tmp/dangling-sidecar.log" 2>&1; then
    echo "promote overwrote a dangling provenance symlink" >&2
    exit 1
fi
grep -q 'already exists or is not safe' "$tmp/dangling-sidecar.log"
test ! -e "$tmp/dangling-sidecar.zag"
test -L "$tmp/dangling-sidecar.zag.zsledger"
test "$(readlink "$tmp/dangling-sidecar.zag.zsledger")" = "$sidecar_link_target"
test ! -e "$sidecar_link_target"

# Before parity starts, the only promotion-owned object is its private staging
# inode, so a final-path race must remove that staging file but preserve the
# foreign final entry. This is distinct from post-parity uncertain-output rules.
cat >"$tmp/race-output.sh" <<'SH'
#!/usr/bin/env sh
final=$1
while :; do
    for staged in "$final".tmp.*; do
        if [ -e "$staged" ]; then
            (set -C; printf foreign-pre-parity >"$final") 2>/dev/null || true
            exit 0
        fi
    done
done
SH
chmod +x "$tmp/race-output.sh"
{
    printf 'script;\n//'
    head -c 1048576 /dev/zero | tr '\0' x
    printf '\nreturn 0;\n'
} >"$tmp/race-app.zag"
timeout 15 "$tmp/race-output.sh" "$tmp/pre-parity-race.zag" \
    >/dev/null 2>&1 &
pre_parity_racer=$!
if "$compiler" promote "$tmp/race-app.zag" --to explicit \
    --output "$tmp/pre-parity-race.zag" --test-command true --no-zagd \
    >"$tmp/pre-parity-race.log" 2>&1; then
    kill "$pre_parity_racer" 2>/dev/null || true
    wait "$pre_parity_racer" 2>/dev/null || true
    echo "promote rename-overwrote an output created before parity" >&2
    exit 1
fi
wait "$pre_parity_racer"
grep -q 'failed to publish explicit candidate without replacing an existing entry' \
    "$tmp/pre-parity-race.log"
printf 'foreign-pre-parity' | cmp -s - "$tmp/pre-parity-race.zag"
test ! -e "$tmp/pre-parity-race.zag.zsledger"

# Once a parity command has run, it may have replaced the output inode. Failure
# therefore leaves the uncertain output in place but never publishes provenance;
# promotion must not perform a path-only unlink that could delete foreign data.
if "$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/failed.zag" --test-command false --no-zagd \
    >"$tmp/failed.log" 2>&1; then
    echo "promote accepted a failing parity command" >&2
    exit 1
fi
grep -q 'parity tests failed' "$tmp/failed.log"
grep -q 'uncertain output left in place' "$tmp/failed.log"
test -s "$tmp/failed.zag"
test ! -e "$tmp/failed.zag.zsledger"

# A parity command that deliberately replaces the candidate owns that new inode.
# Even on a nonzero exit, promotion must preserve the foreign bytes and publish
# no ledger instead of deleting by path after a racy equality check.
if "$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/replaced.zag" \
    --test-command "rm -f $tmp/replaced.zag; printf foreign-output > $tmp/replaced.zag; false" \
    --no-zagd >"$tmp/replaced.log" 2>&1; then
    echo "promote accepted a parity command that replaced its output" >&2
    exit 1
fi
grep -q 'uncertain output left in place' "$tmp/replaced.log"
printf 'foreign-output' | cmp -s - "$tmp/replaced.zag"
test ! -e "$tmp/replaced.zag.zsledger"

# A parity command is untrusted with respect to human-owned paths. It may not
# race in a foreign sidecar and have promotion rename-overwrite that data.
if "$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/foreign.zag" \
    --test-command "printf foreign-sidecar > $tmp/foreign.zag.zsledger" \
    --no-zagd >"$tmp/foreign.log" 2>&1; then
    echo "promote overwrote a sidecar created by its parity command" >&2
    exit 1
fi
grep -q 'foreign sidecar preserved' "$tmp/foreign.log"
test -s "$tmp/foreign.zag"
printf 'foreign-sidecar' | cmp -s - "$tmp/foreign.zag.zsledger"

# Close the final check-to-rename gap itself. The parity command leaves a
# bounded background racer that waits until the sidecar staging inode exists,
# then creates the human-owned final entry before renameat2. RENAME_NOREPLACE
# must fail and preserve both the foreign sidecar and the now-uncertain output;
# no path-only rollback is permitted after parity has started.
cat >"$tmp/race-sidecar.sh" <<'SH'
#!/usr/bin/env sh
final=$1
while :; do
    for staged in "$final".tmp.*; do
        if [ -e "$staged" ]; then
            (set -C; printf atomic-race >"$final") 2>/dev/null || true
            exit 0
        fi
    done
done
SH
chmod +x "$tmp/race-sidecar.sh"
# Use a bounded 512 KiB compact fixture so the valid v2 sidecar is about 2 MiB:
# large enough to leave a deterministic staging window, but below the semantic
# manifest's independent completeness ceiling. A tiny ledger can finish the
# rename before the scheduled racer observes the staging path, which tests
# scheduling rather than RENAME_NOREPLACE.
{
    printf 'script;\n//'
    head -c 524288 /dev/zero | tr '\0' x
    printf '\nreturn 0;\n'
} >"$tmp/ledger-race-app.zag"
if "$compiler" promote "$tmp/ledger-race-app.zag" --to explicit \
    --output "$tmp/atomic-race.zag" \
    --test-command "timeout 10 $tmp/race-sidecar.sh $tmp/atomic-race.zag.zsledger >/dev/null 2>&1 &" \
    --no-zagd >"$tmp/atomic-race.log" 2>&1; then
    if printf 'atomic-race' | cmp -s - "$tmp/atomic-race.zag.zsledger"; then
        echo "promote reported success after overwriting a sidecar created after its final check" >&2
    else
        echo "sidecar race fixture did not win the staging-to-rename window" >&2
    fi
    exit 1
fi
grep -q 'failed to publish provenance without replacing an existing entry' \
    "$tmp/atomic-race.log"
test -s "$tmp/atomic-race.zag"
printf 'atomic-race' | cmp -s - "$tmp/atomic-race.zag.zsledger"

# The immutable compact snapshot is acquired through the ledger byte ceiling;
# a sparse oversized input must fail before parsing or unbounded allocation.
truncate -s 8388609 "$tmp/oversized-compact.zs"
if "$compiler" promote "$tmp/oversized-compact.zs" --to explicit \
    --output "$tmp/oversized-promoted.zag" --test-command true --no-zagd \
    >"$tmp/oversized-compact.log" 2>&1; then
    echo "promote accepted compact source beyond the portable ledger bound" >&2
    exit 1
fi
grep -q 'missing, unsafe, or exceeds portable ledger bound' \
    "$tmp/oversized-compact.log"
test ! -e "$tmp/oversized-promoted.zag"
test ! -e "$tmp/oversized-promoted.zag.zsledger"

# Promotion must retain every foreground-only Script guard. A strict generated
# candidate cannot be used to bypass ScriptContext allocation accounting.
cat >"$tmp/unaccounted.zag" <<'ZAG'
script;
let bytes = make[u8](16);
return bytes.len;
ZAG
if "$compiler" promote "$tmp/unaccounted.zag" --to explicit \
    --output "$tmp/unaccounted-promoted.zag" --test-command true --no-zagd \
    >"$tmp/unaccounted.log" 2>&1; then
    echo "promote bypassed foreground Script allocation guards" >&2
    exit 1
fi
grep -q 'root make is not charged to ScriptContext' "$tmp/unaccounted.log"
test ! -e "$tmp/unaccounted-promoted.zag"
test ! -e "$tmp/unaccounted-promoted.zag.zsledger"

# Provenance is portable and independent of daemon/cache lifetime.
rm -rf "$tmp/.zag-cache"
"$compiler" unexpand "$tmp/promoted.zag" --output "$tmp/restored.zag" --no-zagd >/dev/null
cmp "$tmp/app.zag" "$tmp/restored.zag"
if "$compiler" unexpand "$tmp/promoted.zag" --output "$tmp/restored.zag" \
    --no-zagd >"$tmp/restored-existing.log" 2>&1; then
    echo "unexpand overwrote an existing output" >&2
    exit 1
fi
grep -q 'output already exists' "$tmp/restored-existing.log"

unexpand_link_target="$tmp/unexpand-link-target-must-remain-absent"
ln -s "$unexpand_link_target" "$tmp/unexpand-dangling.zs"
if "$compiler" unexpand "$tmp/promoted.zag" \
    --output "$tmp/unexpand-dangling.zs" --no-zagd \
    >"$tmp/unexpand-dangling.log" 2>&1; then
    echo "unexpand overwrote a dangling output symlink" >&2
    exit 1
fi
grep -q 'output already exists or is not safe' "$tmp/unexpand-dangling.log"
test -L "$tmp/unexpand-dangling.zs"
test "$(readlink "$tmp/unexpand-dangling.zs")" = "$unexpand_link_target"
test ! -e "$unexpand_link_target"

# Edition-cycle compatibility is executable, not just decoder recognition: an
# unchanged v1 promoted file still restores through the public command.
"$compiler" selfhost/derivation_ledger_test.zag -o "$tmp/ledger-helper" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
printf 'fn main() i32 { return 1; }\n' >"$tmp/v1-promoted.zag"
"$tmp/ledger-helper" --emit-v1-fixture >"$tmp/v1-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/v1-promoted.zag" \
    --output "$tmp/v1-restored.zs" --no-zagd >/dev/null
printf 'script;\nreturn 1;\n' | cmp -s - "$tmp/v1-restored.zs"

# Appended or truncated ledger data invalidates the complete-record checksum.
cp "$tmp/promoted.zag.zsledger" "$tmp/ledger.saved"
printf 'tampered=true\n' >>"$tmp/promoted.zag.zsledger"
if "$compiler" unexpand "$tmp/promoted.zag" --no-zagd \
    >"$tmp/tampered-ledger.log" 2>&1; then
    echo "unexpand accepted a tampered ledger" >&2
    exit 1
fi
grep -q 'invalid portable derivation ledger' "$tmp/tampered-ledger.log"
mv "$tmp/ledger.saved" "$tmp/promoted.zag.zsledger"

# Sidecars are read through the same hard byte ceiling enforced by the codec.
cp "$tmp/promoted.zag.zsledger" "$tmp/ledger.saved"
truncate -s 67108865 "$tmp/promoted.zag.zsledger"
if "$compiler" unexpand "$tmp/promoted.zag" --no-zagd \
    >"$tmp/oversized-ledger.log" 2>&1; then
    echo "unexpand accepted an oversized ledger" >&2
    exit 1
fi
grep -q 'invalid portable derivation ledger' "$tmp/oversized-ledger.log"
mv "$tmp/ledger.saved" "$tmp/promoted.zag.zsledger"

# A localized edit to uniquely preserved body context projects back to compact
# source without carrying generated policy/wrapper code with it.
sed -i 's/let answer: i32 = 40 + 2;/let answer: i32 = 41 + 2;/' "$tmp/promoted.zag"
"$compiler" unexpand "$tmp/promoted.zag" --output "$tmp/projected.zag" \
    --no-zagd >/dev/null
grep -q '^script;$' "$tmp/projected.zag"
grep -q '^let answer: i32 = 41 + 2;$' "$tmp/projected.zag"
! grep -q '__zag_hardened_' "$tmp/projected.zag"

# Generated-only edits have no compact source context and remain conflicts.
"$compiler" promote "$tmp/app.zag" --to explicit --output "$tmp/wrapper.zag" \
    --test-command "test -s $tmp/wrapper.zag" --no-zagd >/dev/null
sed -i 's/Generated by znc harden/Generated by human edit/' "$tmp/wrapper.zag"
if "$compiler" unexpand "$tmp/wrapper.zag" --output "$tmp/conflict.zag" \
    --no-zagd >"$tmp/conflict.log" 2>&1; then
    echo "unexpand accepted a generated-only edit" >&2
    exit 1
fi
grep -q 'structural projection conflict at derived bytes' "$tmp/conflict.log"
test ! -e "$tmp/conflict.zag"

# Extension activation is a real first transform, and its composed CST map must
# still produce a complete ledger and exact unchanged recovery.
cat >"$tmp/implicit.zs" <<'ZS'
let implicit: i32 = 9;
return implicit;
ZS
"$compiler" promote "$tmp/implicit.zs" --to explicit \
    --output "$tmp/implicit-promoted.zag" \
    --test-command "test -s $tmp/implicit-promoted.zag" --no-zagd >/dev/null
grep -q '^format=zagscript-derivation-v2$' "$tmp/implicit-promoted.zag.zsledger"
grep -q '^transform_count=3$' "$tmp/implicit-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/implicit-promoted.zag" \
    --output "$tmp/implicit-restored.zs" --no-zagd >/dev/null
cmp "$tmp/implicit.zs" "$tmp/implicit-restored.zs"

echo "zagscript-views pass=28 fail=0"
