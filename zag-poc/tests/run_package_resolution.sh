#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
znc=${ZNC:-"$root/znc"}
work=$(mktemp -d /tmp/zag-package-resolution.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

pass=0
fail=0
cp -R "$root/tests/package_resolution/workspace" "$work/workspace"

compile="$work/workspace/consumer/src/main.zag"
if "$znc" "$compile" --no-zagd --no-foreground-cache -o "$work/app" >"$work/build.out" 2>&1 &&
    "$work/app"; then
    status=$?
else
    status=$?
fi
if [ "$status" -eq 42 ]; then
    printf 'ok  sibling package import resolves through nearest zag.mod and runs natively\n'
    pass=$((pass + 1))
else
    printf 'FAIL sibling package import: compile/run status=%s\n' "$status"
    sed -n '1,12p' "$work/build.out"
    fail=$((fail + 1))
fi

if (cd "$work/workspace/consumer" &&
    "$znc" src/main.zag --no-zagd --no-foreground-cache -o "$work/relative-app" \
        >"$work/relative-build.out" 2>&1 && "$work/relative-app"); then
    relative_status=$?
else
    relative_status=$?
fi
if [ "$relative_status" -eq 42 ]; then
    printf 'ok  project-relative entry path resolves the same sibling package\n'
    pass=$((pass + 1))
else
    printf 'FAIL project-relative package import: compile/run status=%s\n' "$relative_status"
    sed -n '1,12p' "$work/relative-build.out"
    fail=$((fail + 1))
fi

missing="$work/workspace/consumer/src/missing_dependency.zag"
if "$znc" "$missing" --no-zagd --no-foreground-cache -o "$work/missing" >"$work/missing.out" 2>&1; then
    printf 'FAIL undeclared package dependency compiled\n'
    fail=$((fail + 1))
elif grep -q "dependency 'absent' is not declared" "$work/missing.out" && [ ! -e "$work/missing" ]; then
    printf 'ok  undeclared package dependency fails closed\n'
    pass=$((pass + 1))
else
    printf 'FAIL undeclared dependency diagnostic\n'
    sed -n '1,12p' "$work/missing.out"
    fail=$((fail + 1))
fi

missing_module="$work/workspace/consumer/src/missing_module.zag"
if "$znc" "$missing_module" --no-zagd --no-foreground-cache \
    -o "$work/missing-module" >"$work/missing-module.out" 2>&1; then
    printf 'FAIL absent package module compiled\n'
    fail=$((fail + 1))
elif grep -q 'resolved module does not exist' "$work/missing-module.out" &&
    [ ! -e "$work/missing-module" ]; then
    printf 'ok  absent package module fails at its resolved local path\n'
    pass=$((pass + 1))
else
    printf 'FAIL absent package module diagnostic\n'
    sed -n '1,12p' "$work/missing-module.out"
    fail=$((fail + 1))
fi

traversal="$work/workspace/consumer/src/traversal.zag"
if "$znc" "$traversal" --no-zagd --no-foreground-cache -o "$work/traversal" >"$work/traversal.out" 2>&1; then
    printf 'FAIL package traversal compiled\n'
    fail=$((fail + 1))
elif grep -q 'without traversal' "$work/traversal.out" && [ ! -e "$work/traversal" ]; then
    printf 'ok  package module traversal fails closed\n'
    pass=$((pass + 1))
else
    printf 'FAIL traversal diagnostic\n'
    sed -n '1,12p' "$work/traversal.out"
    fail=$((fail + 1))
fi

expect_invalid_dependency_path() {
    case_name=$1
    case_label=$2
    case_source="$work/workspace/$case_name/src/main.zag"
    case_binary="$work/$case_name"
    case_output="$work/$case_name.out"
    if "$znc" "$case_source" --no-zagd --no-foreground-cache \
        -o "$case_binary" >"$case_output" 2>&1; then
        printf 'FAIL %s dependency path compiled\n' "$case_label"
        fail=$((fail + 1))
    elif grep -q "dependency path must be relative and use '/'" "$case_output" &&
        [ ! -e "$case_binary" ]; then
        printf 'ok  %s dependency path fails closed\n' "$case_label"
        pass=$((pass + 1))
    else
        printf 'FAIL %s dependency path diagnostic\n' "$case_label"
        sed -n '1,12p' "$case_output"
        fail=$((fail + 1))
    fi
}

expect_invalid_dependency_path unsafe_absolute absolute
expect_invalid_dependency_path unsafe_home home-expanded
expect_invalid_dependency_path unsafe_scp scp-like
expect_invalid_dependency_path unsafe_backslash backslash

printf 'Package resolution: pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
