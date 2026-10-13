#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source tests/portable.sh
mkdir -p build/zagscript-linux-deployment
source_fingerprint() {
  {
    find selfhost std -type f -name '*.zag' -print0
    printf '%s\0' zag.mod
  } | zag_sort_nul | while IFS= read -r -d '' p; do
    d=$(zag_sha256_file "$p") || exit 1
    printf '%s\0%s\0' "$d" "$p"
  done | zag_sha256_stream
}
source_before=$(source_fingerprint)
cache="build/zagscript-linux-deployment/$source_before"
mkdir -p "$cache"
lockdir="$cache/.authority-lock"
if ! mkdir "$lockdir" 2>/dev/null; then
  echo "Linux deployment authority: another proof is already active for source $source_before" >&2
  exit 1
fi
release_authority_lock() { rmdir "$lockdir" 2>/dev/null || true; }
trap release_authority_lock EXIT HUP INT TERM
ln -sfn ../../../std "$cache/std"
ln -sfn ../../../selfhost "$cache/selfhost"
validated="$cache/validated-source.sha256"
fixed="$cache/znc-fixed"
fixed_prev="$cache/znc-fixed-prev"
seed="$cache/znc-input"

candidate=${ZAGSCRIPT_LINUX_SEED:-}
if [[ -z "$candidate" && -x build/zagscript-final-qualification/znc-linux-x86_64-fresh ]]; then
  candidate="$PWD/build/zagscript-final-qualification/znc-linux-x86_64-fresh"
fi
if [[ -n "$candidate" ]]; then
  cp "$candidate" "$seed"
  chmod +x "$seed"
elif [[ ! -x "$seed" ]]; then
    host=$(zag_native_platform)
    case "$host" in
      macos-arm64)
        compiler=${ZNC:-$(zag_native_compiler "$root")}
        [[ -x "$compiler" ]] || { echo "Linux deployment authority: native macOS compiler missing" >&2; exit 1; }
        "$compiler" selfhost/native/znc.zag --target linux-x86_64 -o "$seed" --no-analyze --no-zagd --no-foreground-cache
        ;;
      linux-x86_64)
        compiler=${ZNC:-$root/znc}
        "$compiler" selfhost/native/znc.zag -o "$seed" --no-analyze --no-zagd --no-foreground-cache
        ;;
      *) echo "Linux deployment authority: unsupported build host $host" >&2; exit 1 ;;
    esac
fi

run_linux() {
  if [[ $(uname -s):$(uname -m) == Linux:x86_64 || $(uname -s):$(uname -m) == Linux:amd64 ]]; then
    bash -lc "$1"
  else
    command -v docker >/dev/null 2>&1 || { echo 'Linux deployment authority: Docker required on non-Linux host' >&2; return 1; }
    docker run --rm -v "$PWD":/work -w /work alpine:3.20 sh -lc "apk add --no-cache bash coreutils findutils file binutils diffutils grep sed gawk tar xz util-linux strace >/dev/null && $1"
  fi
}

# Cheap cache reuse is permitted only for the exact source fingerprint and an
# intact byte-identical fixed-point pair produced by a prior successful run.
if [[ -f "$validated" && -x "$fixed" && -x "$fixed_prev" ]] &&
   [[ $(cat "$validated") == "$source_before" ]] && cmp -s "$fixed_prev" "$fixed"; then
  echo "deployment cache: verified source-bound fixed point $source_before"
else
  linux_cmd=$(cat <<'EOS'
set -euo pipefail
cache="/work/__CACHE__"
seed="$cache/znc-input"
mkdir -p "$cache/empty-path" "$cache/poison"
for tool in cc gcc clang as ld; do printf '#!/bin/sh\nexit 97\n' >"$cache/poison/$tool"; chmod +x "$cache/poison/$tool"; done
file "$seed" | grep -q 'ELF 64-bit.*x86-64'
if readelf -l "$seed" | grep -q 'INTERP'; then echo 'Linux deployment authority: seed is dynamically linked' >&2; exit 1; fi
prev="$seed"
fixed=""
stage=1
while [ "$stage" -le 3 ]; do
  out="$cache/znc-stage$stage"
  echo "deployment rebuild stage $stage"
  /usr/bin/env -i PATH="$cache/empty-path" "$prev" selfhost/native/znc.zag -o "$out" --no-analyze --no-zagd --no-foreground-cache
  chmod +x "$out"
  file "$out" | grep -q 'ELF 64-bit.*x86-64'
  if readelf -l "$out" | grep -q 'INTERP'; then echo "Linux deployment authority: stage $stage is dynamically linked" >&2; exit 1; fi
  if cmp -s "$prev" "$out"; then
    cp "$prev" "$cache/znc-fixed-prev"
    cp "$out" "$cache/znc-fixed"
    fixed="$cache/znc-fixed"
    break
  fi
  prev="$out"
  stage=$((stage+1))
done
[ -n "$fixed" ] || { echo 'Linux deployment authority: no byte-identical fixpoint within 3 rebuilds' >&2; exit 1; }
printf 'fn main() i32 { print_int(42); return 0; }\n' >"$cache/smoke.zag"
/usr/bin/env -i PATH="$cache/empty-path" "$fixed" "$cache/smoke.zag" -o "$cache/smoke" --no-analyze --no-zagd --no-foreground-cache
[ "$("$cache/smoke")" = 42 ]
file "$cache/smoke" | grep -q 'ELF 64-bit.*x86-64'
if readelf -l "$cache/smoke" | grep -q 'INTERP'; then echo 'Linux deployment authority: smoke executable is dynamically linked' >&2; exit 1; fi
PATH="$cache/poison:$PATH" strace -f -qq -e trace=execve -o "$cache/exec.trace" "$fixed" "$cache/smoke.zag" -o "$cache/smoke-traced" --no-analyze --no-zagd --no-foreground-cache >/dev/null
[ "$(grep -c 'execve(' "$cache/exec.trace")" -eq 1 ]
[ "$("$cache/smoke-traced")" = 42 ]
echo 'Linux deployment native/fixpoint authority: PASS'
EOS
)
  linux_cmd=${linux_cmd//__CACHE__/${cache}}
  run_linux "$linux_cmd"
  printf '%s\n' "$source_before" >"$validated"
fi

# Re-run cheap executable/static/no-child checks even when reusing cached proof.
linux_check=$(cat <<'EOS'
set -euo pipefail
cache="/work/__CACHE__"
fixed="$cache/znc-fixed"
prev="$cache/znc-fixed-prev"
cmp -s "$prev" "$fixed"
file "$fixed" | grep -q 'ELF 64-bit.*x86-64'
if readelf -l "$fixed" | grep -q 'INTERP'; then exit 1; fi
"$fixed" version >/dev/null
printf 'fn main() i32 { print_int(42); return 0; }\n' >"$cache/smoke-recheck.zag"
mkdir -p "$cache/empty-path"
/usr/bin/env -i PATH="$cache/empty-path" "$fixed" "$cache/smoke-recheck.zag" -o "$cache/smoke-recheck" --no-analyze --no-zagd --no-foreground-cache
[ "$("$cache/smoke-recheck")" = 42 ]
echo 'Linux deployment cached revalidation: PASS'
EOS
)
linux_check=${linux_check//__CACHE__/${cache}}
run_linux "$linux_check"
source_after=$(source_fingerprint)
[[ "$source_after" == "$source_before" ]] || { echo 'Linux deployment authority: source changed during qualification' >&2; exit 1; }
echo "Linux deployment source snapshot sha256=$source_before"
echo 'ZagScript Linux deployment authority: PASS static x86-64 + empty-PATH fixpoint + native smoke'
