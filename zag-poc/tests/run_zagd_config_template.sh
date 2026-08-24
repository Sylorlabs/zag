#!/usr/bin/env bash
# The shipped policy example is part of the product surface: it must remain a
# real, fail-closed .zagd.conf accepted by the same foreground parser that
# applies Script defaults.  --no-zagd keeps this fixture from starting a
# background process while still exercising configuration consumption.
set -euo pipefail
cd "$(dirname "$0")/.."

znc_bin=${ZNC:-./znc}
case "$znc_bin" in /*) ;; *) znc_bin="$(pwd)/${znc_bin#./}" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-zagd-config-template.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf 'name = "zagd-config-template"\n' >"$tmp/project/zag.mod"
cat >"$tmp/project/app.zag" <<'EOF'
script;
return 0;
EOF

policy_contract=(
    mode=adaptive
    idle_deep=true
    difficulty=simple
    script_optimization=automatic
    regular_optimization=review
    objective=runtime
    trust_mode=stable
    notifications=advisory
    max_workers=1
    stability_window_ms=75
    max_memory_bytes=536870912
    max_cache_bytes=2147483648
    allocator=script_process_arena
    script_memory_bytes=67108864
    cpu=generic
    device=cpu
    layout=compiler_owned
    allow_filesystem_read=true
    allow_filesystem_write=true
    allow_process=true
    environment_allow=
)

validate_policy_contract() {
    local file=$1 entry key definitions exact
    for entry in "${policy_contract[@]}"; do
        key=${entry%%=*}
        definitions=$(awk -F= -v key="$key" '
            {
                candidate=$1
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
                if (candidate == key) { count++ }
            }
            END { print count + 0 }
        ' "$file")
        exact=$(grep -Fxc -- "$entry" "$file" || true)
        if [[ $definitions != 1 || $exact != 1 ]]; then
            printf 'invalid zagd policy default: expected exactly one `%s` in %s\n' \
                "$entry" "$file" >&2
            return 1
        fi
    done
}

validate_policy_contract examples/zagd.conf

# Prove the contract validator rejects both omission and a permissive/wrong
# default instead of merely checking that some policy-like file exists.
grep -v '^idle_deep=true$' examples/zagd.conf >"$tmp/missing.conf"
if validate_policy_contract "$tmp/missing.conf" >/dev/null 2>&1; then
    echo 'policy contract accepted a missing idle_deep default' >&2
    exit 1
fi
sed 's/^trust_mode=stable$/trust_mode=autonomous/' examples/zagd.conf \
    >"$tmp/wrong.conf"
if validate_policy_contract "$tmp/wrong.conf" >/dev/null 2>&1; then
    echo 'policy contract accepted the wrong trust mode default' >&2
    exit 1
fi

# A non-default probe proves the foreground parser accepted every key in the
# template.  If it rejects a new key and silently falls back to defaults, this
# value remains 67108864 and the test fails.
sed 's/^script_memory_bytes=67108864$/script_memory_bytes=1048576/' \
    examples/zagd.conf >"$tmp/project/.zagd.conf"
(cd "$tmp/project" && "$znc_bin" explain app.zag --format json --no-zagd) \
    >"$tmp/parser-probe.json"
grep -q '"script_memory_bytes":{"value":1048576' "$tmp/parser-probe.json"

cp examples/zagd.conf "$tmp/project/.zagd.conf"
(cd "$tmp/project" && "$znc_bin" explain app.zag --format json --no-zagd) \
    >"$tmp/explain.json"
grep -q '"allocator":{"value":"script_process_arena","basis":"derived"}' "$tmp/explain.json"
grep -q '"script_memory_bytes":{"value":67108864' "$tmp/explain.json"
grep -q '"execution_plan":{"cpu":"generic","device":"cpu","layout":"compiler_owned","basis":"derived"}' "$tmp/explain.json"

# A missing file is the one condition that selects documented defaults. This
# remains successful even with daemon startup explicitly disabled.
rm "$tmp/project/.zagd.conf"
(cd "$tmp/project" && "$znc_bin" check app.zag --no-zagd --no-analyze \
    --no-foreground-cache) >"$tmp/missing-config.out" 2>&1

# An existing malformed file is foreground policy input, not an advisory hint.
# Every policy-consuming surface must reject it before compiling, rendering a
# policy-derived native view, starting/stopping a daemon, or publishing owned
# expanded source. `--no-zagd` does not weaken that fail-closed boundary.
printf 'trust_mode=unsafe\n' >"$tmp/project/.zagd.conf"

expect_invalid_config() {
    local label=$1 diagnostic=$2
    shift 2
    set +e
    (cd "$tmp/project" && "$@") >"$tmp/$label.out" 2>&1
    local rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        printf 'malformed .zagd.conf unexpectedly accepted by %s\n' "$label" >&2
        return 1
    fi
    grep -Fq "znc $diagnostic: invalid .zagd.conf:" "$tmp/$label.out"
    grep -Fq 'trust_mode must be stable, reviewed, or autonomous' "$tmp/$label.out"
}

expect_invalid_config source-build source "$znc_bin" app.zag -o invalid-app \
    --no-zagd --no-analyze --no-foreground-cache
test ! -e "$tmp/project/invalid-app"
expect_invalid_config source-check source "$znc_bin" check app.zag \
    --no-zagd --no-analyze --no-foreground-cache
expect_invalid_config explain explain "$znc_bin" explain app.zag --no-zagd
expect_invalid_config native-view view "$znc_bin" view app.zag --level native \
    --no-zagd --no-analyze
expect_invalid_config native-expand expand "$znc_bin" expand app.zag --to native \
    --no-zagd --no-analyze
expect_invalid_config promote promote "$znc_bin" promote app.zag --to explicit \
    --output promoted.zag --test-command true --no-zagd
test ! -e "$tmp/project/promoted.zag"
test ! -e "$tmp/project/promoted.zag.zsledger"
expect_invalid_config suggest suggest "$znc_bin" suggest --format json
expect_invalid_config optimize optimize "$znc_bin" optimize --preview --format json \
    --no-zagd
expect_invalid_config watch watch "$znc_bin" watch --mode off
test ! -e "$tmp/project/.zagd.lock"

echo "zagd config template: PASS"
