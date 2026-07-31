#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
compiler=${ZNC:-"$PWD/znc"}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}";; esac
tmp=$(mktemp -d /tmp/zag-volatile-widths.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf '%s\n' 'name = "x86volatilewidths"' 'version = "0"' 'edition = "2027"' >"$tmp/project/zag.mod"
cp tests/x86/x86_volatile_widths.zag "$tmp/project/main.zag"
"$compiler" "$tmp/project/main.zag" -o "$tmp/app" --cpu=generic --safety=checked --no-zagd --no-analyze >/dev/null
set +e; "$tmp/app"; rc=$?; set -e
if [ "$rc" -ne 42 ]; then echo "x86 volatile width execution failed: $rc" >&2; exit 1; fi
hex=$(od -An -tx1 -v "$tmp/app" | tr -d ' \n')
# 16-bit MMIO uses 66 REX 0F B7/89; 32-bit forms omit REX.W and use 8B/89.
printf '%s' "$hex" | grep -Eq '66(4[0-9a-f]|48|4c)0fb7[0-9a-f]{2}'
printf '%s' "$hex" | grep -Eq '66(4[0-9a-f]|48|4c)89[0-9a-f]{2}'
printf '%s' "$hex" | grep -Eq '(4[0-9a-f])?8b[0-9a-f]{2}'
printf '%s' "$hex" | grep -Eq '(4[0-9a-f])?89[0-9a-f]{2}'
echo "x86 volatile widths: u16/u32 exact-width checked transactions and opcode pass"

reject() {
  local name=$1 source=$2 needle=$3
  mkdir -p "$tmp/$name"
  printf '%s\n' 'name = "x86volatilewidthsnegative"' 'version = "0"' 'edition = "2027"' >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  if "$compiler" "$tmp/$name/main.zag" -o "$tmp/$name/out" --cpu=generic --safety=checked --no-zagd --no-analyze >"$tmp/$name/log" 2>&1 || [ -e "$tmp/$name/out" ]; then
    echo "volatile width negative accepted: $name" >&2
    sed -n '1,10p' "$tmp/$name/log" >&2
    exit 1
  fi
  grep -q "$needle" "$tmp/$name/log"
}

reject wrong-width 'fn main()i32{ let v:i32=0; unsafe { let p:*mut i32=(&v) as *mut i32; @volatileLoad16(p); } return 0; }' 'halfword access requires'
reject const-store 'fn main()i32{ let v:u16=0; unsafe { let p:*const u16=(&v) as *const u16; @volatileStore16(p,7); } return 0; }' 'volatile/MMIO store cannot write through \*const'
reject wrong-value 'fn main()i32{ let v:u16=0; let value:u32=7; unsafe { let p:*mut u16=(&v) as *mut u16; @volatileStore16(p,value); } return 0; }' 'halfword store value must be u16'
reject safe-scope 'fn main()i32{ let v:u32=0; let p:*mut u32=(&v) as *mut u32; @volatileLoad32(p); return 0; }' 'volatile/MMIO access requires unsafe'
echo "x86 volatile widths: width, mutability, and unsafe boundaries reject"
