#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root=$PWD
znc_bin=${ZNC:-./znc}
case "$znc_bin" in
    /*) ;;
    *) znc_bin="$PWD/${znc_bin#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-interpolation.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$znc_bin" "$repo_root/tests/script_interpolation.zag" -o "$tmp/interpolation" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.out" 2>&1
test "$($tmp/interpolation)" = $'hello Zag!\ncount 42 ready true\nnegative -7\nfloat literal 1.5\nnegative float literal -2.5\nfloat variable 1.5 adjusted 1.75\nfloat rounded 1.234568\neq=a=b\n{ok} Zag\n{only}'

# The compact Script bytes are canonical: compiling the same source from an
# unrelated working directory must produce the same self-contained native
# artifact, not a cwd-bound normalization or hidden helper path.
mkdir "$tmp/other-cwd"
mkdir "$tmp/compiler-root"
ln -s "$repo_root/std" "$tmp/compiler-root/std"
ln -s "$repo_root/selfhost" "$tmp/compiler-root/selfhost"
cp "$znc_bin" "$tmp/compiler-root/znc"
chmod +x "$tmp/compiler-root/znc"
(
    cd "$tmp/other-cwd"
    "$tmp/compiler-root/znc" "$repo_root/tests/script_interpolation.zag" \
        -o "$tmp/interpolation-relocated" --no-zagd --no-analyze --no-foreground-cache
) >"$tmp/repro.out" 2>&1
cmp -s "$tmp/interpolation" "$tmp/interpolation-relocated"
test "$($tmp/interpolation-relocated)" = $'hello Zag!\ncount 42 ready true\nnegative -7\nfloat literal 1.5\nnegative float literal -2.5\nfloat variable 1.5 adjusted 1.75\nfloat rounded 1.234568\neq=a=b\n{ok} Zag\n{only}'

# Generated scalar formatting must fail closed when its ScriptContext budget
# is exhausted. Returning an empty slice would silently corrupt the rendered
# output, so the compiler-owned helper reports the boundary and exits.
cat >"$tmp/budget.zag" <<'ZAG'
script;
let fill:*i8 = script_alloc(1048576);
let output = "prefix {1234567890123456789} suffix";
println(output);
return 0;
ZAG
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp/.zagd.conf"
"$znc_bin" "$tmp/budget.zag" -o "$tmp/budget" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/budget.build" 2>&1
test -x "$tmp/budget"
set +e
"$tmp/budget" >"$tmp/budget.out" 2>"$tmp/budget.err"
budget_status=$?
set -e
test "$budget_status" -eq 1
grep -q 'Zag Script string allocation failed' "$tmp/budget.err"

# A strict source string containing braces is not rewritten by the Script
# normalizer.  This guards the profile boundary and keeps strict bytes exact.
printf '%s\n' 'fn main() []u8 { return "strict {bytes}"; }' >"$tmp/strict.zag"
"$znc_bin" check "$tmp/strict.zag" --no-zagd --no-analyze --no-foreground-cache >/dev/null

for bad in unmatched_open unmatched_close empty nested; do
    case "$bad" in
        unmatched_open) source='script; println("bad {name");' ;;
        unmatched_close) source='script; println("bad }");' ;;
        empty) source='script; println("bad {}");' ;;
        nested) source='script; println("bad {a{b}}");' ;;
    esac
    printf '%s\n' "$source" >"$tmp/$bad.zag"
    if "$znc_bin" "$tmp/$bad.zag" -o "$tmp/$bad" --no-zagd \
        --no-analyze --no-foreground-cache >"$tmp/$bad.out" 2>&1; then
        echo "interpolation $bad unexpectedly compiled" >&2
        exit 1
    fi
    test ! -e "$tmp/$bad"
    grep -q 'Zag Script interpolation' "$tmp/$bad.out"
done

echo "script interpolation: pass=13 fail=0"
