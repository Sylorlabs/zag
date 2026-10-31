#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-registry.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$ZNC_BIN" check selfhost/package_registry.zag --analyze-strict \
    --no-zagd --no-foreground-cache >"$tmp/check.log" 2>&1
grep -q 'znc: OK — all capability claims proven' "$tmp/check.log"

"$ZNC_BIN" selfhost/package_registry_test.zag -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1
test -x "$tmp/test"
"$tmp/test" >"$tmp/out"
grep -qx 'package registry protocol: 20/20' "$tmp/out"

mkdir -p "$tmp/resolver/registry/src" "$tmp/resolver/src"
if ! "$ZNC_BIN" tests/package_registry_resolve.zag -o "$tmp/resolver-test" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/resolver-build.log" 2>&1; then
    sed -n '1,80p' "$tmp/resolver-build.log" >&2
    exit 1
fi
test -x "$tmp/resolver-test"
"$tmp/resolver-test" "$tmp/resolver" >"$tmp/resolver.out"
grep -qx 'package registry resolver: 7/7' "$tmp/resolver.out"

# The protocol must also be consumed by the foreground package resolver.  The
# index is local and offline; only the selected source's raw tuple is trusted.
mkdir -p "$tmp/project/registry/src"
cat >"$tmp/project/zag.mod" <<'EOF'
name = "registry-consumer"
version = "0.0.0"
edition = "2026"

[deps]
toolkit = { path = "registry/index.zag", mode = "registry", version = "^1.0.0" }
EOF
cat >"$tmp/project/registry/src/toolkit.zag" <<'EOF'
pub fn answer() i32 { return 42; }
EOF
cat >"$tmp/project/main.zag" <<'EOF'
@import("pkg:toolkit/src/toolkit.zag") as toolkit
fn main() i32 { return toolkit.answer(); }
EOF
raw_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "%d,%d,%d",a,b,n}'
}
registry_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "checksum=%d,%d,%d\n",a,b,n}'
}
source_sum=$(raw_checksum "$tmp/project/registry/src/toolkit.zag")
printf '%s\n' \
    'format=zag-registry-index-v1' \
    'authority=local-file-v1' \
    'signature=none' \
    "entry=toolkit$(printf '\t')1.0.0$(printf '\t')src/toolkit.zag$(printf '\t')$source_sum" \
    >"$tmp/project/registry/index.body"
registry_checksum "$tmp/project/registry/index.body" \
    >>"$tmp/project/registry/index.body"
mv "$tmp/project/registry/index.body" "$tmp/project/registry/index.zag"

if ! (cd "$tmp/project" && "$ZNC_BIN" main.zag -o app \
    --no-zagd --no-analyze --no-foreground-cache >build.log 2>&1); then
    sed -n '1,80p' "$tmp/project/build.log" >&2
    exit 1
fi
test -x "$tmp/project/app"
set +e
"$tmp/project/app"
registry_rc=$?
set -e
test "$registry_rc" -eq 42

cp "$tmp/project/main.zag" "$tmp/project/main.good"
printf '%s\n' \
    '@import("pkg:toolkit/src/not-the-selected.zag") as toolkit' \
    'fn main() i32 { return toolkit.answer(); }' >"$tmp/project/main.zag"
if (cd "$tmp/project" && "$ZNC_BIN" main.zag -o rejected-module \
    --no-zagd --no-analyze --no-foreground-cache >module.log 2>&1); then
    echo 'registry source/module mismatch unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/project/rejected-module"
grep -Fq 'registry index source does not match the requested module path' \
    "$tmp/project/module.log"
mv "$tmp/project/main.good" "$tmp/project/main.zag"

cp "$tmp/project/registry/src/toolkit.zag" "$tmp/toolkit.saved"
printf '%s\n' 'pub fn answer() i32 { return 41; }' \
    >"$tmp/project/registry/src/toolkit.zag"
if (cd "$tmp/project" && "$ZNC_BIN" main.zag -o rejected \
    --no-zagd --no-analyze --no-foreground-cache >checksum.log 2>&1); then
    echo 'registry source mutation unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/project/rejected"
grep -Fq 'checksum' "$tmp/project/checksum.log"
mv "$tmp/toolkit.saved" "$tmp/project/registry/src/toolkit.zag"

# Locked registry sources reject final and parent symlinks before the resolver
# reads bytes.  The ordinary unlocked-local dependency contract is tested
# separately and continues to follow normal kernel semantics.
cp "$tmp/project/registry/src/toolkit.zag" "$tmp/toolkit.real"
printf '%s\n' 'pub fn answer() i32 { return 42; }' \
    >"$tmp/registry-outside.zag"
rm "$tmp/project/registry/src/toolkit.zag"
ln -s "$tmp/registry-outside.zag" \
    "$tmp/project/registry/src/toolkit.zag"
if (cd "$tmp/project" && "$ZNC_BIN" main.zag -o rejected-symlink \
    --no-zagd --no-analyze --no-foreground-cache >symlink.log 2>&1); then
    echo 'registry symlink source unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/project/rejected-symlink"
grep -Fq 'locked package path contains a symlink' \
    "$tmp/project/symlink.log"
rm "$tmp/project/registry/src/toolkit.zag"
mv "$tmp/toolkit.real" "$tmp/project/registry/src/toolkit.zag"

mv "$tmp/project/registry/src" "$tmp/project/registry/src-real"
ln -s src-real "$tmp/project/registry/src"
if (cd "$tmp/project" && "$ZNC_BIN" main.zag -o rejected-parent-symlink \
    --no-zagd --no-analyze --no-foreground-cache >parent-symlink.log 2>&1); then
    echo 'registry parent symlink unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/project/rejected-parent-symlink"
grep -Fq 'locked package path contains a symlink' \
    "$tmp/project/parent-symlink.log"
rm "$tmp/project/registry/src"
mv "$tmp/project/registry/src-real" "$tmp/project/registry/src"

sed 's/version = "\^1\.0\.0"/version = "^2.0.0"/' \
    "$tmp/project/zag.mod" >"$tmp/project/zag.mod.bad"
mv "$tmp/project/zag.mod.bad" "$tmp/project/zag.mod"
if (cd "$tmp/project" && "$ZNC_BIN" main.zag -o rejected-version \
    --no-zagd --no-analyze --no-foreground-cache >version.log 2>&1); then
    echo 'registry incompatible requirement unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/project/rejected-version"
grep -Fq 'version' "$tmp/project/version.log"

# Registry selections compose through the ordinary module loader.  The first
# selected source imports a second registry package whose index lives in a
# different directory; each entry path must remain relative to its containing
# index, and the complete graph must compile/run from the project root.
mkdir -p "$tmp/transitive/registry/src" "$tmp/transitive/registry/dep/src"
cat >"$tmp/transitive/zag.mod" <<'EOF'
name = "registry-transitive-consumer"
version = "0.0.0"
edition = "2026"

[deps]
toolkit = { path = "registry/index.zag", mode = "registry", version = "^1.0.0" }
EOF
cat >"$tmp/transitive/registry/zag.mod" <<'EOF'
name = "registry-transitive-root"
version = "0.0.0"
edition = "2026"

[deps]
dep = { path = "dep/index.zag", mode = "registry", version = "^1.0.0" }
EOF
cat >"$tmp/transitive/registry/src/toolkit.zag" <<'EOF'
@import("pkg:dep/src/dep.zag") as dep
pub fn answer() i32 { return dep.value(); }
EOF
cat >"$tmp/transitive/registry/dep/src/dep.zag" <<'EOF'
pub fn value() i32 { return 42; }
EOF
cat >"$tmp/transitive/main.zag" <<'EOF'
@import("pkg:toolkit/src/toolkit.zag") as toolkit
fn main() i32 { return toolkit.answer(); }
EOF
transitive_index() {
    local index="$1" name="$2" version="$3" rel="$4" source="$5"
    local body="$index.body"
    printf 'format=zag-registry-index-v1\nauthority=local-file-v1\nsignature=none\n' >"$body"
    printf 'entry=%s\t%s\tsrc/%s\t%s\n' "$name" "$version" "$rel" \
        "$(raw_checksum "$source")" >>"$body"
    registry_checksum "$body" >>"$body"
    mv "$body" "$index"
}
transitive_index "$tmp/transitive/registry/index.zag" toolkit 1.0.0 \
    toolkit.zag "$tmp/transitive/registry/src/toolkit.zag"
transitive_index "$tmp/transitive/registry/dep/index.zag" dep 1.0.0 \
    dep.zag "$tmp/transitive/registry/dep/src/dep.zag"
if ! (cd "$tmp/transitive" && "$ZNC_BIN" main.zag -o app \
    --no-zagd --no-analyze --no-foreground-cache >build.log 2>&1); then
    sed -n '1,100p' "$tmp/transitive/build.log" >&2
    exit 1
fi
test -x "$tmp/transitive/app"
set +e
"$tmp/transitive/app"
transitive_rc=$?
set -e
test "$transitive_rc" -eq 42

echo 'package registry protocol: pass (canonical offline index/query, resolver consumption, and fail-closed checks)'
