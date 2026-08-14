#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
caller_dir=$PWD
znc=${ZNC:-"$root/znc"}
case "$znc" in
    /*) ;;
    *) znc="$caller_dir/$znc" ;;
esac
safe_tmp_root=""
for candidate in "/run/user/$(id -u)" /dev/shm /var/tmp /tmp; do
    [ -d "$candidate" ] && [ -w "$candidate" ] || continue
    ancestor=$(cd "$candidate" 2>/dev/null && pwd) || continue
    safe=1
    while :; do
        if [ -e "$ancestor/zag.mod" ]; then
            safe=0
            break
        fi
        [ "$ancestor" = "/" ] && break
        ancestor=$(dirname "$ancestor")
    done
    if [ "$safe" -eq 1 ]; then
        safe_tmp_root="$candidate"
        break
    fi
done
safe_tmp_root=${safe_tmp_root:-${TMPDIR:-/tmp}}
work=$(mktemp -d "$safe_tmp_root/zag-package-resolution.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

pass=0
fail=0
release_evidence=${ZAGSCRIPT_RELEASE_EVIDENCE:-0}
case $release_evidence in
    0|1) ;;
    *)
        printf 'FAIL ZAGSCRIPT_RELEASE_EVIDENCE must be exactly 0 or 1\n'
        exit 2
        ;;
esac

workspace="$root/tests/package_resolution/workspace"
inventory="$root/tests/package_resolution/workspace.inventory.tsv"
generated_inventory="$work/workspace.inventory.generated.tsv"
unsupported=$(find "$workspace" -mindepth 1 \
    ! -type d ! -type f ! -type l -print -quit)
if [ -n "$unsupported" ]; then
    printf 'FAIL package workspace contains unsupported entry: %s\n' "$unsupported"
    exit 1
fi
tab=$(printf '\t')
newline='
'
{
    printf 'format\tzag-package-workspace-inventory-v1\n'
    LC_ALL=C find "$workspace" -mindepth 1 \( -type f -o -type l \) \
        -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sh -c '
            workspace=$1
            tab=$2
            newline=$3
            shift 3
            for relative do
                case $relative in
                    *"$tab"*|*"$newline"*) exit 1 ;;
                esac
                if [ -L "$workspace/$relative" ]; then
                    target=$(readlink -- "$workspace/$relative") || exit 1
                    case $target in
                        *"$tab"*|*"$newline"*) exit 1 ;;
                    esac
                    printf "link\t%s\t%s\n" "$relative" "$target"
                else
                    printf "file\t%s\n" "$relative"
                fi
            done
        ' sh "$workspace" "$tab" "$newline"
} >"$generated_inventory" || {
    printf 'FAIL package workspace inventory contains a non-TSV-safe path or link\n'
    exit 1
}
if [ -f "$inventory" ] && cmp -s "$inventory" "$generated_inventory"; then
    printf 'ok  checked package workspace inventory is complete and exact\n'
    pass=$((pass + 1))
else
    printf 'FAIL package workspace inventory is missing, stale, or malformed\n'
    if [ -f "$inventory" ]; then
        diff -u "$inventory" "$generated_inventory" || true
    fi
    exit 1
fi

artifact_static_x86_exec() {
    artifact=$1
    [ -x "$artifact" ] &&
        LC_ALL=C file -b "$artifact" 2>/dev/null |
            grep -Eq '^ELF 64-bit .* x86-64, .*statically linked' &&
        LC_ALL=C readelf -hW "$artifact" 2>/dev/null | grep -Eq 'Class:[[:space:]]+ELF64' &&
        LC_ALL=C readelf -hW "$artifact" 2>/dev/null | grep -Eq 'Type:[[:space:]]+EXEC' &&
        LC_ALL=C readelf -hW "$artifact" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' &&
        ! LC_ALL=C readelf -lW "$artifact" 2>/dev/null | grep -q 'INTERP' &&
        ! LC_ALL=C readelf -dW "$artifact" 2>/dev/null | grep -q '(NEEDED)'
}

artifact_runs_42() {
    artifact=$1
    if "$artifact"; then artifact_status=0; else artifact_status=$?; fi
    [ "$artifact_status" -eq 42 ]
}

cp -R "$root/tests/package_resolution/workspace" "$work/workspace"

resolver_unit="$work/package-resolver-unit"
resolver_unit_output="$work/package-resolver-unit.out"
if "$znc" "$root/selfhost/package_resolve_test.zag" --no-zagd \
    --no-foreground-cache -o "$resolver_unit" >"$work/package-resolver-unit.build" 2>&1 &&
    artifact_static_x86_exec "$resolver_unit" &&
    (cd "$root" && "$resolver_unit" >"$resolver_unit_output" 2>&1) &&
    [ "$(grep -c '^ok  ' "$resolver_unit_output" || true)" -eq 21 ] &&
    grep -F -x -q 'Package resolver unit: fail=0' "$resolver_unit_output"; then
    printf 'ok  exact resolver ownership, release, checksum, path, and generator unit contract passes 21/21\n'
    pass=$((pass + 1))
else
    printf 'FAIL exact package resolver unit contract\n'
    sed -n '1,24p' "$work/package-resolver-unit.build"
    sed -n '1,24p' "$resolver_unit_output" 2>/dev/null || true
    fail=$((fail + 1))
fi

manifest_inputs_test="$work/zagd-manifest-inputs-test"
manifest_inputs_build="$work/zagd-manifest-inputs-test.build"
parent_manifest="$work/vendor-parent-cwd.semantic"
project_manifest="$work/vendor-project-cwd.semantic"
vendor_project="$work/workspace/vendor_consumer"
if "$znc" "$root/selfhost/zagd_manifest_inputs_test.zag" --no-zagd \
    --no-foreground-cache -o "$manifest_inputs_test" >"$manifest_inputs_build" 2>&1 &&
    artifact_static_x86_exec "$manifest_inputs_test" &&
    (cd "$work/workspace" && "$manifest_inputs_test" \
        vendor_consumer/src/main.zag vendor_consumer/src src/main.zag \
        "$work/workspace" "$vendor_project" "$parent_manifest"); then
    printf 'ok  parent-CWD published package inputs are current under the project root\n'
    pass=$((pass + 1))
else
    printf 'FAIL parent-CWD package semantic input currentness\n'
    sed -n '1,24p' "$manifest_inputs_build"
    fail=$((fail + 1))
fi

if [ -s "$parent_manifest" ] &&
    (cd "$vendor_project" && "$manifest_inputs_test" \
        src/main.zag src src/main.zag "$vendor_project" "$vendor_project" \
        "$project_manifest") &&
    (cd "$vendor_project" && "$manifest_inputs_test" --matches \
        src/main.zag src "$vendor_project" "$vendor_project" \
        "$parent_manifest") &&
    cmp -s "$parent_manifest" "$project_manifest"; then
    printf 'ok  parent/project CWD units match one byte-identical canonical cache graph\n'
    pass=$((pass + 1))
else
    printf 'FAIL package semantic publication depends on compiler CWD\n'
    if [ -f "$parent_manifest" ] && [ -f "$project_manifest" ]; then
        diff -u "$parent_manifest" "$project_manifest" | sed -n '1,40p' || true
    fi
    fail=$((fail + 1))
fi

relocated_parent="$work/relocated-workspace"
relocated_project="$relocated_parent/vendor_consumer"
relocated_manifest="$work/vendor-relocated.semantic"
mkdir -p "$relocated_parent"
cp -R "$vendor_project" "$relocated_project"
if (cd "$relocated_parent" && "$manifest_inputs_test" \
        vendor_consumer/src/main.zag vendor_consumer/src src/main.zag \
        "$relocated_parent" "$relocated_project" "$relocated_manifest") &&
    (cd "$relocated_parent" && "$manifest_inputs_test" --matches \
        vendor_consumer/src/main.zag vendor_consumer/src "$relocated_parent" \
        "$relocated_project" "$parent_manifest") &&
    cmp -s "$parent_manifest" "$relocated_manifest"; then
    printf 'ok  unrelated checkout paths preserve byte-identical manifest and cache graph identities\n'
    pass=$((pass + 1))
else
    printf 'FAIL package semantic/cache identity depends on checkout path\n'
    if [ -f "$parent_manifest" ] && [ -f "$relocated_manifest" ]; then
        diff -u "$parent_manifest" "$relocated_manifest" | sed -n '1,40p' || true
    fi
    fail=$((fail + 1))
fi

cp "$vendor_project/zag.mod" "$work/vendor-zag.mod.saved"
printf '%s\n' '# changed after semantic publication' >>"$vendor_project/zag.mod"
if [ -s "$parent_manifest" ] &&
    ! "$manifest_inputs_test" --current "$vendor_project" "$parent_manifest"; then
    printf 'ok  daemon currentness rejects a changed manifest dependency input\n'
    pass=$((pass + 1))
else
    printf 'FAIL daemon currentness accepted a changed manifest dependency input\n'
    fail=$((fail + 1))
fi
mv "$work/vendor-zag.mod.saved" "$vendor_project/zag.mod"

mv "$vendor_project/zag.lock" "$work/vendor-zag.lock.saved"
if [ -s "$parent_manifest" ] &&
    ! "$manifest_inputs_test" --current "$vendor_project" "$parent_manifest"; then
    printf 'ok  daemon currentness rejects a deleted lock dependency input\n'
    pass=$((pass + 1))
else
    printf 'FAIL daemon currentness accepted a deleted lock dependency input\n'
    fail=$((fail + 1))
fi
mv "$work/vendor-zag.lock.saved" "$vendor_project/zag.lock"

compile="$work/workspace/consumer/src/main.zag"
if "$znc" "$compile" --no-zagd --no-foreground-cache -o "$work/app" >"$work/build.out" 2>&1; then
    if artifact_static_x86_exec "$work/app" && artifact_runs_42 "$work/app"; then
        printf 'ok  sibling package import emits a static x86-64 executable and runs natively\n'
        pass=$((pass + 1))
    else
        printf 'FAIL sibling package import artifact is not static ELF64 x86-64 ET_EXEC or returned the wrong status\n'
        fail=$((fail + 1))
    fi
else
    compile_status=$?
    printf 'FAIL sibling package import: compile status=%s\n' "$compile_status"
    sed -n '1,12p' "$work/build.out"
    fail=$((fail + 1))
fi

if (cd "$work/workspace/consumer" &&
    "$znc" src/main.zag --no-zagd --no-foreground-cache -o "$work/relative-app" \
        >"$work/relative-build.out" 2>&1); then
    if artifact_static_x86_exec "$work/relative-app" &&
        artifact_runs_42 "$work/relative-app"; then
        printf 'ok  project-relative entry emits the same static native program\n'
        pass=$((pass + 1))
    else
        printf 'FAIL project-relative artifact is not static ELF64 x86-64 ET_EXEC or returned the wrong status\n'
        fail=$((fail + 1))
    fi
else
    relative_compile_status=$?
    printf 'FAIL project-relative package import: compile status=%s\n' "$relative_compile_status"
    sed -n '1,12p' "$work/relative-build.out"
    fail=$((fail + 1))
fi

if [ -x "$work/app" ] && [ -x "$work/relative-app" ] &&
    cmp -s "$work/app" "$work/relative-app"; then
    printf 'ok  absolute and project-relative entry paths emit byte-identical artifacts\n'
    pass=$((pass + 1))
else
    printf 'FAIL package resolution artifacts differ across entry-path forms\n'
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
expect_invalid_dependency_path unsafe_url URL

expect_package_failure() {
    case_name=$1
    case_source_rel=$2
    case_label=$3
    expected_diagnostic=$4
    case_source="$work/workspace/$case_source_rel"
    case_binary="$work/$case_name"
    case_output="$work/$case_name.out"
    if "$znc" "$case_source" --no-zagd --no-foreground-cache \
        -o "$case_binary" >"$case_output" 2>&1; then
        printf 'FAIL %s compiled\n' "$case_label"
        fail=$((fail + 1))
    elif grep -F -q "$expected_diagnostic" "$case_output" && [ ! -e "$case_binary" ]; then
        printf 'ok  %s fails closed\n' "$case_label"
        pass=$((pass + 1))
    else
        printf 'FAIL %s diagnostic\n' "$case_label"
        sed -n '1,12p' "$case_output"
        fail=$((fail + 1))
    fi
}

expect_package_failure duplicate_alias duplicate_alias/src/main.zag \
    'duplicate dependency alias' "dependency 'toolkit' is declared more than once"
expect_package_failure missing_manifest missing_manifest/src/main.zag \
    'missing package manifest' "no ancestor zag.mod declares local dependencies"
expect_package_failure malformed_entry malformed_entry/src/main.zag \
    'malformed matching dependency entry' "invalid or missing path entry for dependency 'toolkit'"

shadow_source="$work/workspace/nearest_shadow/outer/inner/src/main.zag"
shadow_binary="$work/nearest-shadow"
shadow_output="$work/nearest-shadow.out"
if "$znc" "$shadow_source" --no-zagd --no-foreground-cache \
    -o "$shadow_binary" >"$shadow_output" 2>&1; then
    printf 'FAIL nearest manifest shadowing fell back to an outer declaration\n'
    fail=$((fail + 1))
elif grep -F -q "dependency 'toolkit' is not declared in" "$shadow_output" &&
    grep -F -q '/nearest_shadow/outer/inner/zag.mod' "$shadow_output" &&
    [ ! -e "$shadow_binary" ]; then
    printf 'ok  nearest manifest shadows an outer dependency declaration\n'
    pass=$((pass + 1))
else
    printf 'FAIL nearest manifest shadowing diagnostic\n'
    sed -n '1,12p' "$shadow_output"
    fail=$((fail + 1))
fi

# Local package declarations follow normal filesystem symlinks.  This proves
# the documented behavior without treating the resolver as a containment
# sandbox: the declared link still points at the explicit sibling fixture.
ln -s ../toolkit "$work/workspace/symlink_dependency/linked-toolkit"
symlink_source="$work/workspace/symlink_dependency/src/main.zag"
symlink_binary="$work/symlink-app"
symlink_output="$work/symlink-build.out"
if "$znc" "$symlink_source" --no-zagd --no-foreground-cache \
    -o "$symlink_binary" >"$symlink_output" 2>&1; then
    if artifact_static_x86_exec "$symlink_binary" &&
        artifact_runs_42 "$symlink_binary"; then
        printf 'ok  declared local dependency follows filesystem symlink semantics\n'
        pass=$((pass + 1))
    else
        printf 'FAIL symlink dependency artifact is not static executable or returned the wrong status\n'
        fail=$((fail + 1))
    fi
else
    symlink_compile_status=$?
    printf 'FAIL declared symlink dependency: compile status=%s\n' "$symlink_compile_status"
    sed -n '1,12p' "$symlink_output"
    fail=$((fail + 1))
fi

vendor_source="$work/workspace/vendor_consumer/src/main.zag"
vendor_binary="$work/vendor-app"
vendor_output="$work/vendor-build.out"
if "$znc" "$vendor_source" --no-zagd --no-foreground-cache \
    -o "$vendor_binary" >"$vendor_output" 2>&1; then
    if artifact_static_x86_exec "$vendor_binary" &&
        artifact_runs_42 "$vendor_binary"; then
        printf 'ok  canonical locked vendor dependency emits static ELF64 x86-64 ET_EXEC and runs\n'
        pass=$((pass + 1))
    else
        printf 'FAIL locked vendor artifact is not a static executable or returned the wrong status\n'
        fail=$((fail + 1))
    fi
else
    printf 'FAIL canonical locked vendor dependency did not compile\n'
    sed -n '1,12p' "$vendor_output"
    fail=$((fail + 1))
fi

if (cd "$work/workspace/vendor_consumer" &&
    "$znc" src/main.zag --no-zagd --no-foreground-cache \
        -o "$work/vendor-relative-app" >"$work/vendor-relative.out" 2>&1); then
    if artifact_static_x86_exec "$work/vendor-relative-app" &&
        artifact_runs_42 "$work/vendor-relative-app" &&
        cmp -s "$vendor_binary" "$work/vendor-relative-app"; then
        printf 'ok  locked vendor builds are executable and byte-identical across entry-path forms\n'
        pass=$((pass + 1))
    else
        printf 'FAIL locked vendor artifacts differ across entry-path forms\n'
        fail=$((fail + 1))
    fi
else
    printf 'FAIL project-relative locked vendor dependency did not compile\n'
    sed -n '1,12p' "$work/vendor-relative.out"
    fail=$((fail + 1))
fi

if env -i "$znc" "$vendor_source" --no-zagd --no-foreground-cache \
    -o "$work/vendor-empty-env-app" >"$work/vendor-empty-env.out" 2>&1 &&
    artifact_static_x86_exec "$work/vendor-empty-env-app" &&
    artifact_runs_42 "$work/vendor-empty-env-app" &&
    cmp -s "$vendor_binary" "$work/vendor-empty-env-app"; then
    printf 'ok  locked vendor compile is environment-independent, executable, and byte-identical\n'
    pass=$((pass + 1))
else
    printf 'FAIL locked vendor compile depends on ambient environment state\n'
    sed -n '1,12p' "$work/vendor-empty-env.out"
    fail=$((fail + 1))
fi

trace_available=0
if command -v strace >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 &&
    timeout 5 strace -qq -e trace=none -o "$work/strace-probe.out" \
        /bin/true >/dev/null 2>&1; then
    trace_available=1
fi
if [ "$trace_available" -eq 1 ]; then
    if strace -f -qq -e trace=network -o "$work/vendor-network.trace" \
        "$znc" "$vendor_source" --no-zagd --no-foreground-cache \
        -o "$work/vendor-traced-app" >"$work/vendor-traced.out" 2>&1 &&
        [ ! -s "$work/vendor-network.trace" ] &&
        artifact_static_x86_exec "$work/vendor-traced-app" &&
        artifact_runs_42 "$work/vendor-traced-app" &&
        cmp -s "$vendor_binary" "$work/vendor-traced-app"; then
        printf 'evidence  locked vendor compile performs zero traced network syscalls and emits the identical executable\n'
    else
        printf 'FAIL locked vendor trace observed network activity or an invalid artifact\n'
        sed -n '1,12p' "$work/vendor-network.trace"
        fail=$((fail + 1))
    fi
elif [ "$release_evidence" = 1 ]; then
    printf 'FAIL release evidence requires usable strace/kernel tracing\n'
    fail=$((fail + 1))
else
    printf 'SKIP network trace unavailable in portable focused mode (not a pass)\n'
fi

cache_case="$work/vendor-cache-revalidation"
cp -R "$work/workspace/vendor_consumer" "$cache_case"
if "$znc" "$cache_case/src/main.zag" --no-zagd --cache-report \
    -o "$cache_case/first" >"$cache_case/first.out" 2>&1 &&
    "$znc" "$cache_case/src/main.zag" --no-zagd --cache-report \
    -o "$cache_case/second" >"$cache_case/second.out" 2>&1 &&
    artifact_static_x86_exec "$cache_case/first" &&
    artifact_static_x86_exec "$cache_case/second" &&
    artifact_runs_42 "$cache_case/first" &&
    artifact_runs_42 "$cache_case/second" &&
    cmp -s "$cache_case/first" "$cache_case/second" &&
    grep -F -q 'znc cache: HIT' "$cache_case/second.out"; then
    mv "$cache_case/zag.lock" "$cache_case/zag.lock.removed"
    if "$znc" "$cache_case/src/main.zag" --no-zagd --cache-report \
        -o "$cache_case/after-removal" >"$cache_case/after-removal.out" 2>&1; then
        printf 'FAIL foreground cache bypassed removed vendor lockfile\n'
        fail=$((fail + 1))
    elif grep -F -q 'vendor dependency requires canonical lockfile' \
        "$cache_case/after-removal.out" && [ ! -e "$cache_case/after-removal" ]; then
        printf 'ok  cached build revalidates vendor policy before machine-cache lookup\n'
        pass=$((pass + 1))
    else
        printf 'FAIL cached vendor revalidation diagnostic\n'
        sed -n '1,12p' "$cache_case/after-removal.out"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL locked vendor fixture did not establish a foreground-cache hit\n'
    sed -n '1,12p' "$cache_case/first.out"
    sed -n '1,12p' "$cache_case/second.out"
    fail=$((fail + 1))
fi

# The resolver snapshots zag.mod/zag.lock once per successful pkg import, and
# the parser deduplicates those raw dependency inputs. Prove both the semantic
# graph and foreground cache react to comment-only provenance changes while the
# native program remains byte-identical.
semantic_fixture="$work/zagd-semantic-fixture"
provenance_case="$work/vendor-provenance"
cp -R "$work/workspace/vendor_consumer" "$provenance_case"
if "$znc" "$root/tests/zagd_semantic_fixture.zag" --no-zagd --no-analyze \
    -o "$semantic_fixture" >"$work/semantic-fixture.out" 2>&1 &&
    artifact_static_x86_exec "$semantic_fixture" &&
    "$znc" "$provenance_case/src/main.zag" --no-zagd --cache-report \
        -o "$provenance_case/first" >"$provenance_case/first.out" 2>&1 &&
    "$znc" "$provenance_case/src/main.zag" --no-zagd --cache-report \
        -o "$provenance_case/second" >"$provenance_case/second.out" 2>&1 &&
    artifact_static_x86_exec "$provenance_case/first" &&
    artifact_static_x86_exec "$provenance_case/second" &&
    artifact_runs_42 "$provenance_case/first" &&
    artifact_runs_42 "$provenance_case/second" &&
    cmp -s "$provenance_case/first" "$provenance_case/second" &&
    grep -F -q 'znc cache: HIT' "$provenance_case/second.out" &&
    (cd "$provenance_case" &&
        "$semantic_fixture" src/main.zag "$work/provenance-before.semantic") &&
    [ "$(grep -F -c "dependency_input_node=zag.mod${tab}" \
        "$work/provenance-before.semantic" || true)" -eq 1 ] &&
    [ "$(grep -F -c "dependency_input_node=zag.lock${tab}" \
        "$work/provenance-before.semantic" || true)" -eq 1 ]; then
    before_graph=$(sed -n 's/^graph=//p' "$work/provenance-before.semantic")
    manifest_graph=

    printf '%s\n' '# manifest provenance comment' >>"$provenance_case/zag.mod"
    if "$znc" "$provenance_case/src/main.zag" --no-zagd --cache-report \
        -o "$provenance_case/after-manifest" \
        >"$provenance_case/after-manifest.out" 2>&1 &&
        grep -F -q 'znc cache: MISS' "$provenance_case/after-manifest.out" &&
        artifact_static_x86_exec "$provenance_case/after-manifest" &&
        artifact_runs_42 "$provenance_case/after-manifest" &&
        cmp -s "$provenance_case/first" "$provenance_case/after-manifest" &&
        (cd "$provenance_case" &&
            "$semantic_fixture" src/main.zag "$work/provenance-manifest.semantic"); then
        manifest_graph=$(sed -n 's/^graph=//p' "$work/provenance-manifest.semantic")
        if [ -n "$before_graph" ] && [ -n "$manifest_graph" ] &&
            [ "$before_graph" != "$manifest_graph" ]; then
            printf 'ok  comment-only zag.mod change invalidates cache/semantic identity without changing native bytes\n'
            pass=$((pass + 1))
        else
            printf 'FAIL comment-only zag.mod change preserved semantic graph identity\n'
            fail=$((fail + 1))
        fi
    else
        printf 'FAIL comment-only zag.mod change did not force a byte-identical executable cache miss\n'
        sed -n '1,12p' "$provenance_case/after-manifest.out"
        fail=$((fail + 1))
    fi

    printf '%s\n' '# lock provenance comment' >>"$provenance_case/zag.lock"
    if "$znc" "$provenance_case/src/main.zag" --no-zagd --cache-report \
        -o "$provenance_case/after-lock" \
        >"$provenance_case/after-lock.out" 2>&1 &&
        grep -F -q 'znc cache: MISS' "$provenance_case/after-lock.out" &&
        artifact_static_x86_exec "$provenance_case/after-lock" &&
        artifact_runs_42 "$provenance_case/after-lock" &&
        cmp -s "$provenance_case/first" "$provenance_case/after-lock" &&
        (cd "$provenance_case" &&
            "$semantic_fixture" src/main.zag "$work/provenance-lock.semantic"); then
        lock_graph=$(sed -n 's/^graph=//p' "$work/provenance-lock.semantic")
        if [ -n "$manifest_graph" ] && [ -n "$lock_graph" ] &&
            [ "$manifest_graph" != "$lock_graph" ]; then
            printf 'ok  comment-only zag.lock change invalidates cache/semantic identity without changing native bytes\n'
            pass=$((pass + 1))
        else
            printf 'FAIL comment-only zag.lock change preserved semantic graph identity\n'
            fail=$((fail + 1))
        fi
    else
        printf 'FAIL comment-only zag.lock change did not force a byte-identical executable cache miss\n'
        sed -n '1,12p' "$provenance_case/after-lock.out"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL package provenance fixture did not establish exact deduplicated dependency inputs\n'
    sed -n '1,12p' "$work/semantic-fixture.out"
    fail=$((fail + 1))
fi

expect_vendor_failure() {
    case_dir=$1
    case_label=$2
    expected_diagnostic=$3
    case_binary="$case_dir/app"
    case_output="$case_dir/build.out"
    if "$znc" "$case_dir/src/main.zag" --no-zagd --no-foreground-cache \
        -o "$case_binary" >"$case_output" 2>&1; then
        printf 'FAIL %s compiled\n' "$case_label"
        fail=$((fail + 1))
    elif grep -F -q "$expected_diagnostic" "$case_output" &&
        [ ! -e "$case_binary" ]; then
        printf 'ok  %s fails closed\n' "$case_label"
        pass=$((pass + 1))
    else
        printf 'FAIL %s diagnostic\n' "$case_label"
        sed -n '1,12p' "$case_output"
        fail=$((fail + 1))
    fi
}

vendor_case="$work/vendor-mutated"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
printf '%s\n' '// raw byte mutation' >>"$vendor_case/vendor/toolkit/src/toolkit.zag"
expect_vendor_failure "$vendor_case" 'mutated vendored module checksum' \
    'vendor module raw checksum mismatch'

vendor_case="$work/vendor-missing-lock"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
rm "$vendor_case/zag.lock"
expect_vendor_failure "$vendor_case" 'missing vendor lockfile' \
    'vendor dependency requires canonical lockfile'

vendor_case="$work/vendor-missing-entry"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
sed -i '/src\/toolkit\.zag/d' "$vendor_case/zag.lock"
expect_vendor_failure "$vendor_case" 'missing exact vendor lock entry' \
    'canonical vendor lockfile has no exact alias/root/module entry'

vendor_case="$work/vendor-reordered-lock"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
sed -i '2{h;d};3G' "$vendor_case/zag.lock"
expect_vendor_failure "$vendor_case" 'reordered vendor lock entries' \
    'invalid canonical vendor lockfile'

vendor_case="$work/vendor-duplicate-lock"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
sed -n '2p' "$vendor_case/zag.lock" >>"$vendor_case/zag.lock"
expect_vendor_failure "$vendor_case" 'duplicate vendor lock entry' \
    'invalid canonical vendor lockfile'

vendor_case="$work/vendor-unknown-record"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
printf '%s\n' 'future=unsupported' >>"$vendor_case/zag.lock"
expect_vendor_failure "$vendor_case" 'unknown vendor lock record' \
    'invalid canonical vendor lockfile'

vendor_case="$work/vendor-unknown-alias"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
printf 'entry=zzunknown\tvendor/toolkit\tsrc/toolkit.zag\t264865380,882918846,86\n' \
    >>"$vendor_case/zag.lock"
expect_vendor_failure "$vendor_case" 'undeclared vendor lock alias' \
    'invalid canonical vendor lockfile'

vendor_case="$work/vendor-noncanonical-checksum"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
sed -i 's/598952360,618734276,34/0598952360,618734276,34/' \
    "$vendor_case/zag.lock"
expect_vendor_failure "$vendor_case" 'noncanonical vendor checksum' \
    'invalid canonical vendor lockfile'

vendor_case="$work/vendor-root-mismatch"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
sed -i 's#vendor/toolkit#vendor/other#g' "$vendor_case/zag.lock"
expect_vendor_failure "$vendor_case" 'lock root mismatch' \
    'invalid canonical vendor lockfile'

vendor_case="$work/vendor-traversal-root"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
sed -i 's#path = "vendor/toolkit"#path = "../toolkit"#' "$vendor_case/zag.mod"
expect_vendor_failure "$vendor_case" 'vendor root traversal' \
    'vendor dependency path must be a traversal-free vendor/<name> root'

vendor_case="$work/vendor-unknown-mode"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
sed -i 's/mode = "vendor"/mode = "registry"/' "$vendor_case/zag.mod"
expect_vendor_failure "$vendor_case" 'unknown dependency mode' \
    'invalid or missing path entry'

vendor_case="$work/vendor-duplicate-mode"
cp -R "$work/workspace/vendor_consumer" "$vendor_case"
sed -i 's/mode = "vendor"/mode = "vendor", mode = "vendor"/' \
    "$vendor_case/zag.mod"
expect_vendor_failure "$vendor_case" 'duplicate vendor manifest field' \
    'invalid or missing path entry'

expected_passes=41
if [ "$pass" -ne "$expected_passes" ]; then
    printf 'FAIL fixed package pass total: expected=%s actual=%s\n' \
        "$expected_passes" "$pass"
    fail=$((fail + 1))
fi
printf 'Package resolution: pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$pass" -eq "$expected_passes" ]
