#!/usr/bin/env bash
# Driver-facing binary layout and unaligned-access contract.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-driver-layout.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

printf 'name = "driver-layout"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
cat >"$tmp/main.zag" <<'EOF'
@repr(C) @align(16) struct Descriptor {
    opcode: u8,
    flags: u8,
    address: u64,
}
@repr(packed) struct PackedBytes { first: u8, second: u8 }

fn main() i32 {
    let size: i64 = @sizeOf[Descriptor]();
    let alignment: i64 = @alignOf[Descriptor]();
    let address_offset: i64 = @offsetOf[Descriptor]("address");
    let packed_size: i64 = @sizeOf[PackedBytes]();
    let packed_second: i64 = @offsetOf[PackedBytes]("second");
    return ((size != 16 || alignment != 16 || address_offset != 8 ||
        packed_size != 2 || packed_second != 1) as i32);
}
EOF
if ! (cd "$tmp" && "$ZNC" main.zag -o out --safety=checked --no-zagd --no-foreground-cache) >"$tmp/positive.log" 2>&1; then
  echo '  XX  layout builtins/valid packed layout did not compile'
  sed -n '1,100p' "$tmp/positive.log"
  exit 1
fi
set +e
"$tmp/out"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "  XX  layout runtime contract failed (exit=$rc)"
  exit 1
fi
echo '  ok  @sizeOf/@alignOf/@offsetOf and valid packed layout lower consistently'

expect_reject() {
  name=$1
  source=$2
  printf '%s\n' "$source" >"$tmp/$name.zag"
  if (cd "$tmp" && "$ZNC" "$name.zag" -o "$name.out" --safety=checked --no-zagd --no-foreground-cache) >"$tmp/$name.log" 2>&1; then
    echo "  XX  $name was accepted"
    exit 1
  fi
  if [ -e "$tmp/$name.out" ]; then
    echo "  XX  $name emitted an artifact after rejection"
    exit 1
  fi
  echo "  ok  $name rejected"
}

expect_reject packed_unaligned '@repr(packed) struct Bad { byte: u8, word: u16 } fn main() i32 { return @sizeOf[Bad](); }'
expect_reject bad_alignment '@align(3) struct Bad { value: u32 } fn main() i32 { return @alignOf[Bad](); }'
expect_reject bad_offset 'struct Descriptor { value: u32 } fn main() i32 { return @offsetOf[Descriptor]("missing"); }'

echo 'driver layout: PASS'
