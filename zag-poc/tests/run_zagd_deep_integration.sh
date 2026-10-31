#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
test_tmp_root=${ZAG_TEST_TMPDIR:-/tmp}
mkdir -p "$test_tmp_root"
tmp=$(mktemp -d "${test_tmp_root%/}/zagd-deep-integration.XXXXXX")
daemon_pid=
trap 'if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; find "$tmp" -depth -delete' EXIT
mkdir -p "$tmp/bin"
if [ -n "${ZAGD:-}" ]; then
    cp "$ZAGD" "$tmp/bin/zagd"
else
    "$compiler" selfhost/zagd_daemon.zag -o "$tmp/bin/zagd" --no-zagd --no-analyze >/dev/null
fi
cp "$compiler" "$tmp/bin/znc"
"$compiler" tests/zagd_finalist_witness.zag -o "$tmp/reference" --no-zagd --no-analyze >/dev/null
cp "$tmp/reference" "$tmp/equivalent"
"$compiler" tests/zagd_finalist_reference_delay.zag -o "$tmp/reference-delay" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_mismatch.zag -o "$tmp/mismatch" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_delay.zag -o "$tmp/delay" --no-zagd --no-analyze >/dev/null

prepare() {
    project=$1 reference=$2 finalist=$3
    mkdir -p "$project"
    cat >"$project/zag.mod" <<'MOD'
name = "deep-integration"
version = "0"
edition = "2026"
MOD
    printf 'fn main() i32 { return 0; }\n' >"$project/main.zag"
    printf '%s\n' "$reference" >"$project/.zagd.deep-reference"
    printf '%s\n' "$finalist" >"$project/.zagd.deep-finalist"
    (cd "$project" && "$tmp/bin/znc" check main.zag --no-zagd --no-analyze >/dev/null)
}

prepare "$tmp/equal" "$tmp/reference" "$tmp/equivalent"
"$tmp/bin/zagd" --root "$tmp/equal" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
for _ in $(seq 1 150); do [ -f "$tmp/equal/.zag-cache/zagd/deep-measurement.record" ] && break; sleep .02; done
record="$tmp/equal/.zag-cache/zagd/deep-measurement.record"
test -f "$record"
grep -q '^format=zagd-deep-measurement-v2$' "$record"
grep -q '^equivalence=exact-output-stderr-exit-signal-state$' "$record"
grep -q '^foreground_consumption=false$' "$record"
grep -q '^provenance=measured$' "$record"
grep -q '^cpu_profile=x86-64-v1$' "$record"
grep -q '^target_cache_key=linux-x86_64|x86-64-v1|sse2$' "$record"
grep -Eq '^semantic_identity=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$record"
grep -Eq '^target=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$record"
grep -q '^runs=3$' "$record"
grep -q '^policy_status=verified_no_win$' "$record"
grep -q '^policy_evidence=complete-warmup-calibration-30-pair-evidence$' "$record"
grep -q '^policy_evaluated=1$' "$record"
grep -q '^policy_eligible=0$' "$record"
policy_record="$tmp/equal/.zag-cache/zagd/benchmark-policy.record"
test -f "$policy_record"
grep -q '^format=zagd-benchmark-evidence-v2$' "$policy_record"
grep -q '^advisory=true$' "$policy_record"
grep -q '^executable_authority=false$' "$policy_record"
grep -q '^foreground_consumption=none$' "$policy_record"
grep -Eq '^reference_identity=-?[0-9]+[[:blank:]]-?[0-9]+[[:blank:]][0-9]+$' "$policy_record"
grep -Eq '^finalist_identity=-?[0-9]+[[:blank:]]-?[0-9]+[[:blank:]][0-9]+$' "$policy_record"
grep -Eq '^semantic_identity=-?[0-9]+[[:blank:]]-?[0-9]+[[:blank:]][0-9]+$' "$policy_record"
grep -q '^target_cache_key=linux-x86_64|x86-64-v1|sse2$' "$policy_record"
grep -Eq '^target_identity=-?[0-9]+[[:blank:]]-?[0-9]+[[:blank:]][0-9]+$' "$policy_record"
grep -q '^workload_count=1$' "$policy_record"
grep -q '^workload=1$' "$policy_record"
grep -q '^policy_status=verified_no_win$' "$policy_record"
grep -q '^policy_evaluated=1$' "$policy_record"
grep -q '^policy_eligible=0$' "$policy_record"
grep -Eq '^peak_memory_bytes=[1-9][0-9]*$' "$policy_record"
grep -Eq '^binary_size_bytes=[1-9][0-9]*$' "$policy_record"
grep -q '^policy_runtime_score_ns=0$' "$policy_record"
grep -Eq '^checksum_first=-?[0-9]+$' "$policy_record"
grep -Eq '^checksum_second=-?[0-9]+$' "$policy_record"
grep -Eq '^checksum_bytes=[0-9]+$' "$policy_record"
for sample_spec in \
    'reference_warmups:3' 'finalist_warmups:3' \
    'noise_reference:30' 'noise_repeat:30' \
    'reference_runs:30' 'finalist_runs:30'; do
    sample_name=${sample_spec%%:*}
    sample_count=${sample_spec##*:}
    actual_count=$(awk -F= -v key="$sample_name" '$1==key {n=split($2,a,","); print n}' "$policy_record")
    test "$actual_count" = "$sample_count"
done
printf stop >"$tmp/equal/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

# A real measured winner: the delayed reference and witness finalist are
# behaviorally identical, while the reference deliberately costs ~20 ms.
# The daemon must complete the 3 warmups, 30 calibration pairs, and 30 paired
# runs before publishing the advisory winner record.
prepare "$tmp/winner" "$tmp/reference-delay" "$tmp/reference"
cp tests/optimize_accept_i32.zag "$tmp/winner/main.zag"
(cd "$tmp/winner" && "$tmp/bin/znc" check main.zag --no-zagd --no-analyze >/dev/null)
cat >"$tmp/transform-reference.zag" <<'ZAG'
struct TransformReferenceTimespec { sec:i64, nsec:i64 }
fn main() i32 {
    let delay:TransformReferenceTimespec=TransformReferenceTimespec{.sec=0,.nsec=20000000};
    let _slept:i64=_zag_raw_syscall(35,(&delay) as i64,0,0,0,0,0);
    let x:i32=1+2;
    return x;
}
ZAG
"$tmp/bin/znc" "$tmp/transform-reference.zag" -o "$tmp/transform-reference" --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/bin/znc" "$tmp/winner/main.zag" -o "$tmp/winner-candidate" --foreground-transform const-i32-add-v1 --no-zagd --no-analyze --no-foreground-cache >/dev/null
printf '%s\n' "$tmp/transform-reference" >"$tmp/winner/.zagd.deep-reference"
printf '%s\n' "$tmp/winner-candidate" >"$tmp/winner/.zagd.deep-finalist"
"$tmp/bin/zagd" --root "$tmp/winner" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
for _ in $(seq 1 2500); do
    test -f "$tmp/winner/.zag-cache/zagd/deep-measurement.record" && break
    sleep .02
done
winner_record="$tmp/winner/.zag-cache/zagd/deep-measurement.record"
test -f "$winner_record"
grep -q '^policy_status=verified_best_measured$' "$winner_record"
grep -q '^policy_winner_kind=1$' "$winner_record"
grep -q '^policy_evaluated=1$' "$winner_record"
grep -q '^policy_eligible=1$' "$winner_record"
grep -q '^policy_no_regression=1$' "$winner_record"
winner_policy="$tmp/winner/.zag-cache/zagd/benchmark-policy.record"
test -f "$winner_policy"
grep -q '^policy_status=verified_best_measured$' "$winner_policy"
grep -q '^policy_winner_kind=1$' "$winner_policy"
grep -q '^transform=const-i32-add-v1$' "$winner_policy"
grep -q '^policy_eligible=1$' "$winner_policy"
grep -Eq '^peak_memory_bytes=[1-9][0-9]*$' "$winner_policy"
grep -Eq '^binary_size_bytes=[1-9][0-9]*$' "$winner_policy"
grep -Eq '^policy_runtime_score_ns=[1-9][0-9]*$' "$winner_policy"
printf stop >"$tmp/winner/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

# The winner record is now a real, source-bound foreground handoff input. The
# compiler still owns rule proof and differential execution; the daemon only
# supplies the measured candidate selector evidence.
accepted="$tmp/winner/accepted"
"$tmp/bin/znc" optimize --accept const-i32-add-v1 "$tmp/winner/main.zag" -o "$accepted" --from-zagd --no-zagd >/dev/null
test -x "$accepted"
set +e
"$accepted" >/dev/null 2>&1
accepted_rc=$?
set -e
test "$accepted_rc" = 3

# The same measured winner envelope must also be consumable by an automatic
# Script build.  The daemon's production record is deliberately rebound to a
# fresh Script semantic manifest here: this keeps the test on one real
# measured-winner artifact without launching another 30-pair daemon run.  The
# helper only changes the semantic identity and recomputes the record checksum;
# payload hashes, samples, selector result, target, and transform identity all
# remain the daemon-produced values.
script_winner="$tmp/script-winner"
mkdir -p "$script_winner/.zag-cache/zagd"
cat >"$script_winner/zag.mod" <<'MOD'
name = "script-auto-winner"
version = "0"
edition = "2026"
MOD
# Bind the Script project to the same declared generic/x86-64-v1 cache profile
# used by the measured winner record.  Without this explicit profile the
# project default is `generic`, whose canonical cache key is intentionally
# different and must (correctly) reject the winner as stale.
printf 'mode=off\nscript_optimization=automatic\ncpu=x86-64-v1\n' >"$script_winner/.zagd.conf"
cat >"$script_winner/main.zag" <<'ZAG'
script;
fn calc() i32 { return 1 + 2; }
return calc();
ZAG
(cd "$script_winner" && "$tmp/bin/znc" check main.zag --no-zagd --no-analyze >/dev/null)
printf '%s' "$(sed -n '/fn zag_version()/s/.*return \"\([^\"]*\)\".*/\1/p' selfhost/version.zag)" \
    >"$script_winner/.zag-cache/.cache-version"
# Prime the foreground cache-version boundary before installing the advisory
# policy record.  A first normal source command may purge a cache created by a
# check-only invocation; after this fixed-point stamp, the copied winner is
# not mistaken for a stale pre-version artifact.
(cd "$script_winner" && "$tmp/bin/znc" view main.zag --level native --no-analyze >/dev/null)
cp "$winner_policy" "$script_winner/.zag-cache/zagd/benchmark-policy.record"
cat >"$tmp/rebind-semantic.zag" <<ZAG
@import("$PWD/selfhost/zagd_profile.zag")
@import("$PWD/selfhost/version.zag")
extern fn _zag_read_file(path:[]u8)[]u8
extern fn _zag_write_file(path:[]u8,content:[]u8)i32

fn hash_text(h:ZagdHash)[]u8{
    return _zag_str_concat(_zag_i64_to_str(h.first),_zag_str_concat("\t",
        _zag_str_concat(_zag_i64_to_str(h.second),_zag_str_concat("\t",_zag_i64_to_str(h.bytes)))));
}
fn replace_semantic_identity(text:[]u8,value:[]u8)[]u8{
    let mark:i32=zagd_find_checksum(text);if(mark<0){return "";}
    let body:[]u8=text[0..mark];let out:ArrayList[u8]=make[u8](body.len+96);
    let key:[]u8="semantic_identity=";let start:i32=0;let i:i32=0;
    while(i<=body.len){
        if(i==body.len||body[i]=='\n'){
            let line:[]u8=body[start..i];
            if(line.len>=key.len&&@strEq(line[0..key.len],key)){
                zagd_text_append(&out,key);zagd_text_append(&out,value);
            }else{zagd_text_append(&out,line);}
            if(i<body.len){zagd_text_append_byte(&out,'\n');}
            start=i+1;
        }
        i=i+1;
    }
    return out.data[0..out.len];
}
fn main()i32{
    if(_zag_argc()!=4){return 1;}
    let policy:[]u8=_zag_read_file(_zag_arg(1));let semantic:[]u8=_zag_read_file(_zag_arg(2));
    if(policy.len<=0||semantic.len<=0){return 2;}
    let identity:ZagdHash=zagd_profile_semantic_identity(semantic,zag_version(),"linux-x86_64|x86-64-v1|sse2");
    if(identity.bytes<=0){return 3;}
    let body:[]u8=replace_semantic_identity(policy,hash_text(identity));if(body.len<=0){return 4;}
    let sum:ZagdHash=zagd_content_hash(body);
    let out:[]u8=_zag_str_concat(body,_zag_str_concat("checksum_first=",
        _zag_str_concat(_zag_i64_to_str(sum.first),_zag_str_concat("\nchecksum_second=",
        _zag_str_concat(_zag_i64_to_str(sum.second),_zag_str_concat("\nchecksum_bytes=",
        _zag_str_concat(_zag_i64_to_str(sum.bytes),"\n")))))));
    if(_zag_write_file(_zag_arg(3),out)!=0){return 5;}
    return 0;
}
ZAG
"$tmp/bin/znc" "$tmp/rebind-semantic.zag" -o "$tmp/rebind-semantic" --no-zagd --no-analyze >/dev/null
"$tmp/rebind-semantic" \
    "$script_winner/.zag-cache/zagd/benchmark-policy.record" \
    "$script_winner/.zag-cache/zagd/semantic.record" \
    "$script_winner/.zag-cache/zagd/benchmark-policy.record.rebound"
mv "$script_winner/.zag-cache/zagd/benchmark-policy.record.rebound" \
    "$script_winner/.zag-cache/zagd/benchmark-policy.record"
test -f "$script_winner/.zag-cache/zagd/benchmark-policy.record"
script_auto="$script_winner/script-auto"
(cd "$script_winner" && "$tmp/bin/znc" main.zag -o "$script_auto" --no-analyze >/dev/null)
set +e
"$script_auto" >/dev/null 2>&1
script_auto_rc=$?
set -e
test "$script_auto_rc" = 3
"$tmp/bin/znc" view "$script_winner/main.zag" --level native --no-analyze >"$tmp/script-winner-view"
grep -q '^// semantic-transform-status=foreground_source_policy_checked rule=const-i32-add-v1 checker=const-i32-add-source-policy-check-v1 transform_count=1 artifact_transform_consumed=0$' \
    "$tmp/script-winner-view"
grep -q '%v3 = arith.constant 3 : i32' "$tmp/script-winner-view"

prepare "$tmp/mismatch-project" "$tmp/reference" "$tmp/mismatch"
"$tmp/bin/zagd" --root "$tmp/mismatch-project" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
sleep .3
test ! -e "$tmp/mismatch-project/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/mismatch-project/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

prepare "$tmp/stale" "$tmp/delay" "$tmp/delay"
"$tmp/bin/zagd" --root "$tmp/stale" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
sleep .05; printf '// invalidates finalist snapshot\n' >>"$tmp/stale/main.zag"
sleep .7
test ! -e "$tmp/stale/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/stale/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

# Rapid editor/agent atomic saves must cancel the obsolete deep finalist.  A
# deep result becomes eligible only after the final stable source receives the
# normal foreground semantic witness; no intermediate save may publish one.
prepare "$tmp/rapid-final" "$tmp/delay" "$tmp/delay"
"$tmp/bin/zagd" --root "$tmp/rapid-final" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
sleep .05
for i in $(seq 1 20); do
    printf 'fn main() i32 { return 0; }\n// partial agent edit %s\n' "$i" >"$tmp/rapid-final/.main.zag.tmp"
    mv "$tmp/rapid-final/.main.zag.tmp" "$tmp/rapid-final/main.zag"
done
printf 'fn main() i32 { return 0; }\n// final stable agent edit\n' >"$tmp/rapid-final/.main.zag.final"
mv "$tmp/rapid-final/.main.zag.final" "$tmp/rapid-final/main.zag"
sleep .7
test ! -e "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record"
(cd "$tmp/rapid-final" && "$tmp/bin/znc" check main.zag --no-zagd --no-analyze >/dev/null)
for _ in $(seq 1 1000); do
    test -f "$tmp/rapid-final/.zag-cache/zagd/semantic.record" && break
    sleep .02
done
test -f "$tmp/rapid-final/.zag-cache/zagd/semantic.record"
for _ in $(seq 1 2500); do
    test -f "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record" && break
    sleep .02
done
grep -q '^format=zagd-deep-measurement-v2$' "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record"
grep -q '^runs=3$' "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record"
grep -q '^policy_status=verified_no_win$' "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record"
grep -q '^policy_evidence=complete-warmup-calibration-30-pair-evidence$' "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record"
test -f "$tmp/rapid-final/.zag-cache/zagd/benchmark-policy.record"
grep -q '^format=zagd-benchmark-evidence-v2$' "$tmp/rapid-final/.zag-cache/zagd/benchmark-policy.record"
printf stop >"$tmp/rapid-final/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

# A root-only source check is insufficient: any imported module changed while a
# finalist is running invalidates the whole semantic/module-graph witness.
mkdir -p "$tmp/import-stale"
cat >"$tmp/import-stale/zag.mod" <<'MOD'
name = "deep-import-stale"
version = "0"
edition = "2026"
MOD
printf 'pub fn helper() i32 { return 0; }\n' >"$tmp/import-stale/lib.zag"
printf '@import("lib.zag")\nfn main() i32 { return helper(); }\n' >"$tmp/import-stale/main.zag"
printf '%s\n' "$tmp/delay" >"$tmp/import-stale/.zagd.deep-reference"
printf '%s\n' "$tmp/delay" >"$tmp/import-stale/.zagd.deep-finalist"
(cd "$tmp/import-stale" && "$tmp/bin/znc" check main.zag --no-zagd --no-analyze >/dev/null)
"$tmp/bin/zagd" --root "$tmp/import-stale" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
sleep .05
printf '// dependency changed during finalist\n' >>"$tmp/import-stale/lib.zag"
sleep .7
test ! -e "$tmp/import-stale/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/import-stale/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

prepare "$tmp/light" "$tmp/reference" "$tmp/equivalent"
"$tmp/bin/zagd" --root "$tmp/light" --root-source main.zag --mode light --window-ms 10 & daemon_pid=$!
sleep .2
test ! -e "$tmp/light/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/light/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

# Adaptive mode used to report idle_deep=true while remaining blocked forever
# in read(2).  Opt-in evidence waits for the real 30-second inactivity window
# and proves that the existing deep-control measurement path is reached without
# changing the public mode or making the daemon a correctness dependency.
if [ "${ZAGD_IDLE_DEEP:-0}" = 1 ]; then
    prepare "$tmp/adaptive-idle" "$tmp/reference" "$tmp/equivalent"
    "$tmp/bin/zagd" --root "$tmp/adaptive-idle" --root-source main.zag \
        --mode adaptive --window-ms 10 & daemon_pid=$!
    for _ in $(seq 1 45); do
        test -f "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record" && break
        sleep 1
    done
    test -f "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record"
    grep -q '^mode=deep$' "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record"
    grep -q '^runs=3$' "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record"
    printf stop >"$tmp/adaptive-idle/.zagd.stop"; wait "$daemon_pid"; daemon_pid=
fi
echo 'zagd deep product integration: pass'
