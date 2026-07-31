#!/usr/bin/env bash
# Edition-2027 mutation-aware aggregate ownership/stack provenance.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in
  /*) ;;
  *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-v2-aggregate-provenance.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
export ZAG_AGG_TEST_ZNC="$ZNC"
ZNC="$tmp/znc-no-zagd"
printf '%s\n' '#!/usr/bin/env bash' 'exec "$ZAG_AGG_TEST_ZNC" "$@" --no-zagd --no-analyze' >"$ZNC"
chmod +x "$ZNC"
pass=0 fail=0

project() {
  name=$1 edition=${2:-2027}
  mkdir -p "$tmp/$name"
  printf 'name = "%s"\nversion = "0"\nedition = "%s"\n' "$name" "$edition" >"$tmp/$name/zag.mod"
}

accept() {
  name=$1 label=$2
  if (cd "$tmp/$name" && "$ZNC" check main.zag) >"$tmp/$name/log" 2>&1; then
    echo "  ok  $label"; pass=$((pass + 1))
  else
    echo "  XX  $label"; sed -n '1,10p' "$tmp/$name/log"; fail=$((fail + 1))
  fi
}

reject() {
  name=$1 label=$2 diagnostic=$3
  if (cd "$tmp/$name" && "$ZNC" main.zag -o out) >"$tmp/$name/log" 2>&1 || [ -e "$tmp/$name/out" ]; then
    echo "  XX  $label"; sed -n '1,10p' "$tmp/$name/log"; fail=$((fail + 1))
  elif grep -q "$diagnostic" "$tmp/$name/log"; then
    echo "  ok  $label"; pass=$((pass + 1))
  else
    echo "  XX  $label (missing diagnostic)"; sed -n '1,10p' "$tmp/$name/log"; fail=$((fail + 1))
  fi
}

echo "── edition-2027 aggregate provenance ──"

project owner-nested-pass
printf '%s\n' \
  'struct Node { value:i32 } struct Inner { ptr:*mut Node } struct Outer { inner:Inner }' \
  'fn retain(value:Outer) void { }' \
  'fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Outer=Outer{.inner=Inner{.ptr=p}}; retain(value); delete(p); } return 0; }' \
  >"$tmp/owner-nested-pass/main.zag"
reject owner-nested-pass "nested named owner cannot escape through an uncontracted call" 'owned allocation escapes through uncontracted call `retain`'

project owner-field-update-pass
printf '%s\n' \
  'struct Node { value:i32 } struct Box { ptr:*mut Node }' \
  'fn retain(value:Box) void { }' \
  'fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Box=Box{.ptr=null as *mut Node}; value.ptr=p; retain(value); delete(p); } return 0; }' \
  >"$tmp/owner-field-update-pass/main.zag"
reject owner-field-update-pass "field assignment records owner provenance" 'owned allocation escapes through uncontracted call `retain`'

project owner-copy-survives-clear
printf '%s\n' \
  'struct Node { value:i32 } struct Box { ptr:*mut Node }' \
  'fn retain(value:Box) void { }' \
  'fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Box=Box{.ptr=p}; let copied:Box=value; value.ptr=null as *mut Node; retain(copied); delete(p); } return 0; }' \
  >"$tmp/owner-copy-survives-clear/main.zag"
reject owner-copy-survives-clear "aggregate copy keeps independent owner provenance" 'owned allocation escapes through uncontracted call `retain`'

project owner-return
printf '%s\n' \
  'struct Node { value:i32 } struct Box { ptr:*mut Node }' \
  'fn bad() Box { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Box=Box{.ptr=p}; return value; } }' \
  'fn main() i32 { return 0; }' \
  >"$tmp/owner-return/main.zag"
reject owner-return "aggregate owner return fails closed" 'owned allocation stored in an aggregate escapes through return'

project owner-store
printf '%s\n' \
  'struct Node { value:i32 } struct Box { ptr:*mut Node }' \
  'fn bad(out:*mut Box) void { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Box=Box{.ptr=p}; out.* = value; delete(p); } }' \
  'fn main() i32 { return 0; }' \
  >"$tmp/owner-store/main.zag"
reject owner-store "aggregate owner cannot escape through an indirect store" 'owned allocation escapes through non-local aggregate store'

project owner-partial-overwrite
printf '%s\n' \
  'struct Node { value:i32 } struct Pair { first:*mut Node, second:*mut Node }' \
  'fn retain(value:Pair) void { }' \
  'fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let q:*mut Node=new(Node{.value=2}) as *mut Node; let value:Pair=Pair{.first=p,.second=q}; value.first=null as *mut Node; retain(value); delete(p); delete(q); } return 0; }' \
  >"$tmp/owner-partial-overwrite/main.zag"
reject owner-partial-overwrite "overwriting one field preserves sibling provenance" 'root `q`'

project owner-branch-may
printf '%s\n' \
  'struct Node { value:i32 } struct Box { ptr:*mut Node }' \
  'fn retain(value:Box) void { }' \
  'fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Box=Box{.ptr=null as *mut Node}; if (1 == 1) { value.ptr=p; } retain(value); delete(p); } return 0; }' \
  >"$tmp/owner-branch-may/main.zag"
reject owner-branch-may "branch join retains may-provenance" 'owned allocation escapes through uncontracted call `retain`'

# Deep nested paths are tracked exactly rather than switching to a bounded
# prefix approximation. A clear at the final field must remove the precise
# provenance entry even after more than 64 components.
project owner-deep-clear
over_types='struct Node { value:i32 } struct Nest64 { ptr:*mut Node }'
i=63
while [ "$i" -ge 0 ]; do
  over_types="$over_types struct Nest$i { next:Nest$((i + 1)) }"
  i=$((i - 1))
done
over_expr=''
i=0
while [ "$i" -lt 64 ]; do
  over_expr="$over_expr"'Nest'"$i"'{.next='
  i=$((i + 1))
done
over_expr="$over_expr"'Nest64{.ptr=p}'
i=0
while [ "$i" -lt 64 ]; do over_expr="$over_expr"'}'; i=$((i + 1)); done
deep_path=''
i=0
while [ "$i" -lt 64 ]; do deep_path="${deep_path}next."; i=$((i + 1)); done
deep_path="${deep_path}ptr"
printf '%s\n' \
  "$over_types" \
  'fn inspect(value:Nest0) void @borrows { }' \
  "fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Nest0=$over_expr; value.$deep_path=null as *mut Node; inspect(value); delete(p); } return 0; }" \
  >"$tmp/owner-deep-clear/main.zag"
accept owner-deep-clear "deep field clear removes exact owner provenance"

project stack-deep-clear
stack_types='struct Nest64 { ptr:*const i32 }'
i=63
while [ "$i" -ge 0 ]; do
  stack_types="$stack_types struct Nest$i { next:Nest$((i + 1)) }"
  i=$((i - 1))
done
stack_expr=''
i=0
while [ "$i" -lt 64 ]; do stack_expr="$stack_expr"'Nest'"$i"'{.next='; i=$((i + 1)); done
stack_expr="$stack_expr"'Nest64{.ptr=(&x) as *const i32}'
i=0
while [ "$i" -lt 64 ]; do stack_expr="$stack_expr"'}'; i=$((i + 1)); done
printf '%s\n' \
  "$stack_types" \
  "fn safe() Nest0 { let x:i32=42; unsafe { let value:Nest0=$stack_expr; value.$deep_path=null as *const i32; return value; } }" \
  'fn main() i32 { let value:Nest0=safe(); return 0; }' \
  >"$tmp/stack-deep-clear/main.zag"
accept stack-deep-clear "deep field clear removes exact stack provenance"

project owner-safe-clear
printf '%s\n' \
  'struct Node { value:i32 } struct Inner { ptr:*mut Node } struct Outer { inner:Inner }' \
  'fn inspect(value:Outer) void @borrows { }' \
  'fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Outer=Outer{.inner=Inner{.ptr=p}}; value.inner.ptr=null as *mut Node; inspect(value); delete(p); } return 0; }' \
  >"$tmp/owner-safe-clear/main.zag"
accept owner-safe-clear "nested owner field clear removes only cleared provenance"

project owner-safe-copy-clear
printf '%s\n' \
  'struct Node { value:i32 } struct Box { ptr:*mut Node }' \
  'fn inspect(value:Box) void @borrows { }' \
  'fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; let value:Box=Box{.ptr=p}; let copied:Box=value; value.ptr=null as *mut Node; copied.ptr=null as *mut Node; inspect(copied); delete(p); } return 0; }' \
  >"$tmp/owner-safe-copy-clear/main.zag"
accept owner-safe-copy-clear "clearing both aggregate copies removes both aliases"

project stack-field-return
printf '%s\n' \
  'struct Box { ptr:*const i32 }' \
  'fn bad() Box { let x:i32=42; unsafe { let value:Box=Box{.ptr=null as *const i32}; value.ptr=(&x) as *const i32; return value; } }' \
  'fn main() i32 { return 0; }' \
  >"$tmp/stack-field-return/main.zag"
reject stack-field-return "field-assigned stack address cannot return" 'address of local `x` escapes through return'

project stack-pass
printf '%s\n' \
  'struct Box { ptr:*const i32 } fn retain(value:Box) void { }' \
  'fn main() i32 { let x:i32=42; unsafe { let value:Box=Box{.ptr=(&x) as *const i32}; retain(value); } return 0; }' \
  >"$tmp/stack-pass/main.zag"
reject stack-pass "aggregate stack address cannot pass to an uncontracted call" 'escapes through aggregate argument to uncontracted call `retain`'

project stack-extract-return
printf '%s\n' \
  'struct Box { ptr:*const i32 }' \
  'fn bad() *const i32 { let x:i32=42; unsafe { let value:Box=Box{.ptr=(&x) as *const i32}; let extracted:*const i32=value.ptr; return extracted; } }' \
  'fn main() i32 { return 0; }' \
  >"$tmp/stack-extract-return/main.zag"
reject stack-extract-return "stored stack address remains tracked after field extraction" 'address of local `x` escapes through return'

project stack-safe-clear
printf '%s\n' \
  'struct Box { ptr:*const i32 }' \
  'fn safe() Box { let x:i32=42; unsafe { let value:Box=Box{.ptr=(&x) as *const i32}; value.ptr=null as *const i32; return value; } }' \
  'fn main() i32 { return 0; }' \
  >"$tmp/stack-safe-clear/main.zag"
accept stack-safe-clear "overwriting a stack-address field permits a safe aggregate return"

project edition-2026-compat 2026
printf '%s\n' \
  'struct Box { ptr:*i32 }' \
  'fn legacy() Box { let x:i32=42; let value:Box=Box{.ptr=&x}; return value; }' \
  'fn main() i32 { return 0; }' \
  >"$tmp/edition-2026-compat/main.zag"
accept edition-2026-compat "edition-2026 aggregate behavior remains unchanged"

echo "════ aggregate-provenance pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
