#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=$(realpath "${ZNC:-./znc}")
tmp=$(mktemp -d /tmp/zag-script-capabilities.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

printf 'script;\nlet data=read_file("input.txt");\nprintln(data);\n' >"$tmp/read.zag"
printf 'allow_filesystem_read=false\nallow_filesystem_write=true\nallow_process=true\nmode=off\n' >"$tmp/.zagd.conf"
if "$znc_bin" "$tmp/read.zag" -o "$tmp/read" --no-zagd --no-analyze >"$tmp/out" 2>&1; then echo "denied filesystem capability unexpectedly compiled" >&2; exit 1; fi
grep -q 'read_file denied by allow_filesystem_read=false' "$tmp/out"
"$znc_bin" explain "$tmp/read.zag" --format json --no-zagd >"$tmp/explain.json"
grep -q '"filesystem_read":false,"filesystem_write":true,"process":true' "$tmp/explain.json"
grep -q '"environment_lookup":false,"environment_allow":""' "$tmp/explain.json"
grep -q '"policy_satisfied":false,"denied_operation_count":1' "$tmp/explain.json"

printf 'script;\nfn read_file(path:[]u8)[]u8{return "local";}\nprintln(read_file("ignored"));\n' >"$tmp/override.zag"
"$znc_bin" "$tmp/override.zag" -o "$tmp/override" --no-zagd --no-analyze >/dev/null
test "$("$tmp/override")" = local

# Environment is Script-root-only and fail-closed. A dynamic name cannot be
# checked against policy, an empty allowlist denies the prelude, and direct raw
# runtime lookup is not a bypass. Allowed values are read-only views; unset
# values are ordinary empty slices.
printf 'script;\nprintln(env("ZAG_SCRIPT_ENV_TEST"));\n' >"$tmp/env.zag"
printf 'allow_filesystem_read=true\nallow_filesystem_write=true\nallow_process=true\nmode=off\n' >"$tmp/.zagd.conf"
if "$znc_bin" "$tmp/env.zag" -o "$tmp/env" --no-zagd --no-analyze >"$tmp/out" 2>&1; then echo "denied environment capability unexpectedly compiled" >&2; exit 1; fi
grep -q 'env("ZAG_SCRIPT_ENV_TEST") denied' "$tmp/out"
"$znc_bin" explain "$tmp/env.zag" --format json --no-zagd >"$tmp/env-denied.json"
grep -q '"environment_lookup":false,"environment_allow":""' "$tmp/env-denied.json"
grep -q '"policy_satisfied":false,"denied_operation_count":1' "$tmp/env-denied.json"

printf 'environment_allow=ZAG_SCRIPT_ENV_TEST,ZAG_SCRIPT_ENV_MISSING\nallow_filesystem_read=true\nallow_filesystem_write=true\nallow_process=true\nmode=off\n' >"$tmp/.zagd.conf"
ZAG_SCRIPT_ENV_TEST=visible "$znc_bin" "$tmp/env.zag" -o "$tmp/env" --no-zagd --no-analyze >/dev/null
test "$(ZAG_SCRIPT_ENV_TEST=visible "$tmp/env")" = visible
printf 'script;\nlet value=env("ZAG_SCRIPT_ENV_MISSING");\nif(value.len != 0){return 1;}\nreturn 0;\n' >"$tmp/env-missing.zag"
"$znc_bin" "$tmp/env-missing.zag" -o "$tmp/env-missing" --no-zagd --no-analyze >/dev/null
"$tmp/env-missing"
"$znc_bin" explain "$tmp/env.zag" --format json --no-zagd >"$tmp/env-allowed.json"
grep -q '"environment_lookup":true,"environment_allow":"ZAG_SCRIPT_ENV_TEST,ZAG_SCRIPT_ENV_MISSING"' "$tmp/env-allowed.json"
grep -q '"operation":"env","allocation":{"value":"zero","bytes":"0"' "$tmp/env-allowed.json"
if "$znc_bin" check "$tmp/env.zag" --strict --no-zagd >"$tmp/out" 2>&1; then echo "strict Script environment promotion unexpectedly passed" >&2; exit 1; fi
grep -q 'unresolved: environment capability has no explicit strict-Zag policy' "$tmp/out"
printf 'script;\nlet name="ZAG_SCRIPT_ENV_TEST";\nprintln(env(name));\n' >"$tmp/env-dynamic.zag"
if "$znc_bin" "$tmp/env-dynamic.zag" -o "$tmp/env-dynamic" --no-zagd --no-analyze >"$tmp/out" 2>&1; then echo "dynamic Script environment lookup unexpectedly compiled" >&2; exit 1; fi
grep -q 'env requires a literal simple variable name' "$tmp/out"
printf 'script;\nprintln(_zag_getenv("ZAG_SCRIPT_ENV_TEST"));\n' >"$tmp/env-raw.zag"
if "$znc_bin" "$tmp/env-raw.zag" -o "$tmp/env-raw" --no-zagd --no-analyze >"$tmp/out" 2>&1; then echo "raw Script environment lookup unexpectedly compiled" >&2; exit 1; fi
grep -q 'direct _zag_getenv is unavailable in Zag Script' "$tmp/out"

printf 'script;\nlet result=process_run_timeout("true",100,16);\nreturn 0;\n' >"$tmp/process.zag"
printf 'allow_filesystem_read=true\nallow_filesystem_write=true\nallow_process=false\nmode=off\n' >"$tmp/.zagd.conf"
if "$znc_bin" "$tmp/process.zag" -o "$tmp/process" --no-zagd --no-analyze >"$tmp/out" 2>&1; then echo "denied process capability unexpectedly compiled" >&2; exit 1; fi
grep -q 'process_run_timeout denied by allow_process=false' "$tmp/out"

printf 'allow_process=maybe\nmode=off\n' >"$tmp/.zagd.conf"
"$znc_bin" "$tmp/read.zag" -o "$tmp/defaulted" --no-zagd --no-analyze >"$tmp/out" 2>&1
grep -q 'allow_process must be true or false; using documented defaults' "$tmp/out"

printf 'allow_filesystem_read=true\nallow_filesystem_write=true\nallow_process=true\nmode=off\n' >"$tmp/.zagd.conf"
printf ok >"$tmp/input.txt"
(cd "$tmp" && "$znc_bin" read.zag -o read --no-zagd --no-analyze >/dev/null && ./read) | grep -q '^ok$'

# Supported execution defaults are embedded in the compiler-owned context.
# The native lowering validates the packed policy before allocating it.
printf 'script;\nreturn 0;\n' >"$tmp/policy.zag"
printf 'allow_filesystem_read=true\nallow_filesystem_write=false\nallow_process=false\ncpu=native\nallocator=script_process_arena\ndevice=cpu\nlayout=compiler_owned\nmode=off\n' >"$tmp/.zagd.conf"
(cd "$tmp" && "$znc_bin" policy.zag -o native-policy --no-zagd --no-analyze >/dev/null && ./native-policy)

printf 'device=gpu\nlayout=compiler_owned\nallocator=script_process_arena\ncpu=generic\nmode=off\n' >"$tmp/.zagd.conf"
if (cd "$tmp" && "$znc_bin" policy.zag -o bad-device --no-zagd --no-analyze >bad-device.log 2>&1); then
    echo "unsupported Script device policy unexpectedly compiled" >&2
    exit 1
fi
grep -q 'unsupported Zag Script planner default' "$tmp/bad-device.log"
test ! -e "$tmp/bad-device"
if (cd "$tmp" && "$znc_bin" check policy.zag --no-zagd >bad-device-check.log 2>&1); then
    echo "check accepted an unsupported Script device policy" >&2
    exit 1
fi
grep -q 'unsupported Zag Script planner default' "$tmp/bad-device-check.log"
if (cd "$tmp" && "$znc_bin" explain policy.zag --format json --no-zagd >bad-device-explain.log 2>&1); then
    echo "explain accepted an unsupported Script device policy" >&2
    exit 1
fi
grep -q 'unsupported Zag Script planner default' "$tmp/bad-device-explain.log"
if (cd "$tmp" && "$znc_bin" harden policy.zag \
    --output bad-device-hardened.zag --no-zagd >bad-device-harden.log 2>&1); then
    echo "harden accepted an unsupported Script device policy" >&2
    exit 1
fi
grep -q 'unsupported Zag Script planner default' "$tmp/bad-device-harden.log"
test ! -e "$tmp/bad-device-hardened.zag"

printf 'device=cpu\nlayout=array_of_structs\nallocator=script_process_arena\ncpu=generic\nmode=off\n' >"$tmp/.zagd.conf"
if (cd "$tmp" && "$znc_bin" policy.zag -o bad-layout --no-zagd --no-analyze >bad-layout.log 2>&1); then
    echo "unsupported Script layout policy unexpectedly compiled" >&2
    exit 1
fi
grep -q 'unsupported Zag Script planner default' "$tmp/bad-layout.log"
test ! -e "$tmp/bad-layout"

printf 'device=cpu\nlayout=compiler_owned\nallocator=script_process_arena\ncpu=runtime\nmode=off\n' >"$tmp/.zagd.conf"
if (cd "$tmp" && "$znc_bin" policy.zag -o bad-cpu --no-zagd --no-analyze >bad-cpu.log 2>&1); then
    echo "unsupported Script runtime-dispatch CPU policy unexpectedly compiled" >&2
    exit 1
fi
grep -q 'unsupported Zag Script CPU policy' "$tmp/bad-cpu.log"
test ! -e "$tmp/bad-cpu"

# Explicit supported choices replace every unsupported configured default
# before the context metadata is generated.
printf 'device=gpu\nlayout=array_of_structs\nallocator=custom\ncpu=unknown\nmode=off\n' >"$tmp/.zagd.conf"
(cd "$tmp" && "$znc_bin" policy.zag -o explicit-policy \
    --script-allocator script_process_arena --device cpu \
    --layout compiler_owned --cpu generic --no-zagd --no-analyze >/dev/null &&
    ./explicit-policy)
echo "script capabilities: PASS"
