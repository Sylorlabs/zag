#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-registry-lock-generator.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

project="$tmp/project"
mkdir -p "$project/registry/src" "$project/src"
cat >"$project/zag.mod" <<'EOF'
name = "registry-generator-fixture"
version = "0.0.0"
edition = "2026"

[deps]
toolkit = { path = "registry/index.zag", mode = "registry", version = "^1.0.0" }
EOF
cat >"$project/src/main.zag" <<'EOF'
@import("pkg:toolkit/src/toolkit.zag") as toolkit
fn main() i32 { return toolkit.answer(); }
EOF
cat >"$project/registry/src/toolkit.zag" <<'EOF'
pub fn answer() i32 { return 42; }
EOF

raw_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "%d,%d,%d",a,b,n}'
}
index_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "checksum=%d,%d,%d\n",a,b,n}'
}
lock_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "checksum=%d,%d,%d\n",a,b,n}'
}
source_sum=$(raw_checksum "$project/registry/src/toolkit.zag")
{
    printf '%s\n' 'format=zag-registry-index-v1' 'authority=local-file-v1' 'signature=none'
    printf 'entry=toolkit\t1.0.0\tsrc/toolkit.zag\t%s\n' "$source_sum"
} >"$project/registry/index.body"
index_checksum "$project/registry/index.body" >>"$project/registry/index.body"
mv "$project/registry/index.body" "$project/registry/index.zag"

if ! (cd "$project" && "$ZNC_BIN" package registry-lock src/main.zag \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/generate.log" 2>&1); then
    sed -n '1,80p' "$tmp/generate.log" >&2
    exit 1
fi
test -f "$project/registry.lock"
grep -Fxq 'format=zag-registry-lock-v1' "$project/registry.lock"
grep -Fq $'entry=toolkit\tregistry/index.zag\t' "$project/registry.lock"
grep -Fq $'\t1.0.0\tsrc/toolkit.zag\t' "$project/registry.lock"
grep -q '^checksum=' "$project/registry.lock"

before=$(sha256sum "$project/registry.lock" | awk '{print $1}')
if (cd "$project" && "$ZNC_BIN" package registry-lock src/main.zag \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/repeat.log" 2>&1); then
    echo 'registry-lock generator unexpectedly replaced its existing output' >&2
    exit 1
fi
after=$(sha256sum "$project/registry.lock" | awk '{print $1}')
test "$before" = "$after"
grep -Fq 'refusing to replace existing lock' "$tmp/repeat.log"

# The generated pin becomes resolver input only after an explicit manifest
# choice; generation itself never edits zag.mod.
sed -i 's#mode = "registry", version = "\^1.0.0"#mode = "registry", version = "^1.0.0", registry_lock = "registry.lock"#' \
    "$project/zag.mod"
if ! (cd "$project" && "$ZNC_BIN" src/main.zag -o app \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1); then
    sed -n '1,100p' "$tmp/build.log" >&2
    exit 1
fi
test -x "$project/app"
set +e
"$project/app"
rc=$?
set -e
test "$rc" -eq 42

# A nested registry manifest may explicitly reuse the root sidecar. The
# generator emits scoped v2 entries, and checksum-valid mutations must still
# fail at the resolver's scope/version provenance boundary.
transitive="$tmp/transitive"
mkdir -p "$transitive/registry/src" "$transitive/registry/dep/src" "$transitive/src"
cat >"$transitive/zag.mod" <<'EOF'
name = "registry-generator-transitive"
version = "0.0.0"
edition = "2026"

[deps]
toolkit = { path = "registry/index.zag", mode = "registry", version = "^1.0.0" }
EOF
cat >"$transitive/registry/zag.mod" <<'EOF'
name = "registry-generator-nested"
version = "0.0.0"
edition = "2026"

[deps]
dep = { path = "dep/index.zag", mode = "registry", version = "^1.0.0", registry_lock = "../registry.lock" }
EOF
cat >"$transitive/src/main.zag" <<'EOF'
@import("pkg:toolkit/src/toolkit.zag") as toolkit
fn main() i32 { return toolkit.answer(); }
EOF
cat >"$transitive/registry/src/toolkit.zag" <<'EOF'
@import("pkg:dep/src/dep.zag") as dep
pub fn answer() i32 { return dep.value(); }
EOF
cat >"$transitive/registry/dep/src/dep.zag" <<'EOF'
pub fn value() i32 { return 42; }
EOF
transitive_index() {
    local index="$1" name="$2" version="$3" rel="$4" source="$5"
    local body="$index.body"
    printf 'format=zag-registry-index-v1\nauthority=local-file-v1\nsignature=none\n' >"$body"
    printf 'entry=%s\t%s\tsrc/%s\t%s\n' "$name" "$version" "$rel" \
        "$(raw_checksum "$source")" >>"$body"
    index_checksum "$body" >>"$body"
    mv "$body" "$index"
}
transitive_index "$transitive/registry/index.zag" toolkit 1.0.0 \
    toolkit.zag "$transitive/registry/src/toolkit.zag"
transitive_index "$transitive/registry/dep/index.zag" dep 1.0.0 \
    dep.zag "$transitive/registry/dep/src/dep.zag"
if ! (cd "$transitive" && "$ZNC_BIN" package registry-lock src/main.zag \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/transitive-generate.log" 2>&1); then
    sed -n '1,100p' "$tmp/transitive-generate.log" >&2
    exit 1
fi
grep -Fxq 'format=zag-registry-lock-v2' "$transitive/registry.lock"
grep -Fq $'entry=root\ttoolkit\tregistry/index.zag\t' "$transitive/registry.lock"
grep -Fq $'entry=registry\tdep\tdep/index.zag\t' "$transitive/registry.lock"
echo 'ok  nested registry selections produce scoped v2 lock entries'

sed -i 's#mode = "registry", version = "\^1.0.0"#mode = "registry", version = "^1.0.0", registry_lock = "registry.lock"#' \
    "$transitive/zag.mod"
if ! (cd "$transitive" && "$ZNC_BIN" src/main.zag -o app \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/transitive-build.log" 2>&1); then
    sed -n '1,100p' "$tmp/transitive-build.log" >&2
    exit 1
fi
set +e
"$transitive/app"
transitive_rc=$?
set -e
test "$transitive_rc" -eq 42
echo 'ok  explicitly declared nested scopes replay from one v2 lock'

rewrite_lock() {
    local lock="$1"
    sed '/^checksum=/d' "$lock" >"$lock.body"
    lock_checksum "$lock.body" >>"$lock.body"
    mv "$lock.body" "$lock"
}
cp "$transitive/registry.lock" "$tmp/transitive.lock.good"
sed -i 's#entry=registry\tdep\tdep/index.zag\t\([0-9,]*\)\t1.0.0\t#entry=registry\tdep\tdep/index.zag\t\1\t1.0.1\t#' \
    "$transitive/registry.lock"
rewrite_lock "$transitive/registry.lock"
if (cd "$transitive" && "$ZNC_BIN" src/main.zag -o rejected-version \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/transitive-version.log" 2>&1); then
    echo 'checksum-valid nested version mutation unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$transitive/rejected-version"
echo 'ok  checksum-valid nested version mutation fails closed'
cp "$tmp/transitive.lock.good" "$transitive/registry.lock"
sed -i 's#entry=registry\tdep\tdep/index.zag\t#entry=wrong\tdep\tdep/index.zag\t#' \
    "$transitive/registry.lock"
rewrite_lock "$transitive/registry.lock"
if (cd "$transitive" && "$ZNC_BIN" src/main.zag -o rejected-scope \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/transitive-scope.log" 2>&1); then
    echo 'checksum-valid nested scope mutation unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$transitive/rejected-scope"
echo 'ok  checksum-valid nested scope mutation fails closed'

echo 'package registry-lock generator: pass=9 fail=0'
