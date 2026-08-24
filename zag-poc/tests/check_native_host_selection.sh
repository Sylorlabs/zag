#!/usr/bin/env bash
# Build-free regression for native host routing and clean seed preservation.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

work=$(mktemp -d "${TMPDIR:-/tmp}/zag-host-selection.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin"

# run_native_vsa.sh intentionally reads uname rather than accepting a production
# host override. This shim lets the selector-only mode cover every matrix row.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    '    -s) printf "%s\\n" "$ZAG_FAKE_UNAME_SYSTEM" ;;' \
    '    -m) printf "%s\\n" "$ZAG_FAKE_UNAME_MACHINE" ;;' \
    '    *) /usr/bin/uname "$@" ;;' \
    'esac' >"$work/bin/uname"
chmod +x "$work/bin/uname"

pass=0
fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

require_line() {
    local text=$1 expected=$2 label=$3
    if grep -Fxq "$expected" <<<"$text"; then ok "$label"; else
        bad "$label (missing '$expected')"
    fi
}

vsa_probe() {
    local system=$1 machine=$2
    ZAG_FAKE_UNAME_SYSTEM=$system \
    ZAG_FAKE_UNAME_MACHINE=$machine \
    ZAG_NATIVE_VSA_HOST_SELECTION_ONLY=1 \
    QEMU_AARCH64= \
    PATH="$work/bin:$PATH" \
        bash tests/run_native_vsa.sh
}

portable_probe() {
    local system=$1 machine=$2
    ZAG_FAKE_UNAME_SYSTEM=$system \
    ZAG_FAKE_UNAME_MACHINE=$machine \
    PATH="$work/bin:$PATH" \
        bash -c '. ./tests/portable.sh; zag_native_platform; zag_native_compiler /checkout; zag_native_daemon /checkout; zag_native_lsp /checkout'
}

echo "── native host selection matrix ──"

out=$(vsa_probe Darwin arm64)
require_line "$out" 'native_platform=macos-arm64' 'VSA selects native macOS ARM64'
require_line "$out" 'native_target_args=--target macos-arm64' 'VSA uses Mach-O target for Darwin runtime'
require_line "$out" 'linux_arm_target_args=--target arm64' 'VSA keeps Linux ARM cross target distinct'
require_line "$out" 'linux_arm_available=0' 'VSA refuses direct Linux ELF execution on Darwin'

out=$(vsa_probe Linux x86_64)
require_line "$out" 'native_platform=linux-x86_64' 'VSA selects Linux x86-64'
require_line "$out" 'native_target_args=<default>' 'VSA keeps Linux x86-64 default target'

out=$(vsa_probe Linux amd64)
require_line "$out" 'native_platform=linux-x86_64' 'VSA accepts Linux amd64 alias'

out=$(vsa_probe Linux aarch64)
require_line "$out" 'native_platform=linux-arm64' 'VSA selects Linux aarch64'
require_line "$out" 'native_target_args=--target arm64' 'VSA uses Linux ARM64 target on Linux'
require_line "$out" 'linux_arm_available=1' 'VSA runs Linux ARM rows natively on Linux ARM64'

out=$(vsa_probe Linux arm64)
require_line "$out" 'native_platform=linux-arm64' 'VSA accepts Linux arm64 alias'

if out=$(vsa_probe Darwin x86_64 2>&1); then
    bad 'VSA rejects Darwin x86-64/Rosetta'
elif grep -Fq 'unsupported native host: Darwin x86_64' <<<"$out"; then
    ok 'VSA rejects Darwin x86-64/Rosetta'
else
    bad 'VSA unsupported-host diagnostic is stable'
fi

out=$(portable_probe Darwin arm64)
require_line "$out" 'macos-arm64' 'portable helper selects macOS ARM64 platform'
require_line "$out" '/checkout/znc-macos-arm64' 'portable helper selects qualified macOS compiler'
require_line "$out" '/checkout/zagd-macos-arm64' 'portable helper selects qualified macOS daemon'
require_line "$out" '/checkout/zag-lsp-macos-arm64' 'portable helper selects qualified macOS LSP'

out=$(portable_probe Linux x86_64)
require_line "$out" '/checkout/znc' 'portable helper keeps Linux x86 compiler name'

out=$(portable_probe Linux aarch64)
require_line "$out" '/checkout/znc-linux-arm64' 'portable helper selects qualified Linux ARM compiler'

out=$(make -s HOST_ID=Darwin-arm64 print-native-host)
if grep -Fq 'platform=macos-arm64 target_args=--target macos-arm64 znc=./znc-macos-arm64' <<<"$out"; then
    ok 'Make selects Darwin ARM64 toolchain'
else
    bad 'Make Darwin ARM64 selection'
fi

for host in Linux-x86_64 Linux-amd64; do
    out=$(make -s HOST_ID=$host print-native-host)
    if grep -Fq "host=$host platform=linux-x86_64" <<<"$out" &&
       grep -Fq 'znc=./znc zagd=./zagd lsp=./zag-lsp' <<<"$out"; then
        ok "Make selects $host toolchain"
    else
        bad "Make $host selection"
    fi
done

for host in Linux-aarch64 Linux-arm64; do
    out=$(make -s HOST_ID=$host print-native-host)
    if grep -Fq "host=$host platform=linux-arm64 target_args=--target arm64" <<<"$out" &&
       grep -Fq 'znc=./znc-linux-arm64 zagd=./zagd-linux-arm64 lsp=./zag-lsp-linux-arm64' <<<"$out"; then
        ok "Make selects $host toolchain"
    else
        bad "Make $host selection"
    fi
done

if make -s HOST_ID=Darwin-x86_64 print-native-host >"$work/make-bad.out" 2>"$work/make-bad.err"; then
    bad 'Make rejects Darwin x86-64/Rosetta'
elif grep -Fq "unsupported native host 'Darwin-x86_64'" "$work/make-bad.err"; then
    ok 'Make rejects Darwin x86-64/Rosetta'
else
    bad 'Make unsupported-host diagnostic is stable'
fi

make -n HOST_ID=Darwin-arm64 >"$work/make-default.out"
if grep -Fq 'ZAG_BOOTSTRAP_OUTPUT="./znc-macos-arm64"' "$work/make-default.out"; then
    ok 'Make default goal remains the native bootstrap'
else
    bad 'Make default goal remains the native bootstrap'
fi

for host in Darwin-arm64 Linux-aarch64 Linux-x86_64; do
    make -n HOST_ID=$host clean >"$work/clean-$host.out"
    if grep -Eq 'rm .*\b(znc|zagd|zag-lsp)-(macos|linux)-arm64\b' "$work/clean-$host.out"; then
        bad "make clean preserves platform toolchain on $host"
    elif grep -Fq 'native compiler/daemon/LSP seeds preserved' "$work/clean-$host.out"; then
        ok "make clean preserves platform toolchain on $host"
    else
        bad "make clean preservation message on $host"
    fi
done

echo "════ host-selection pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
