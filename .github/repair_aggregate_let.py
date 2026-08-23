from pathlib import Path

source = Path("zag-poc/selfhost/native/ncodegen.zag")
text = source.read_text()
old = '''                    if (rt_agg == 0) {
                        switch (initexpr.*) {
                            .call => |_c| { rt_agg = 1; }
                            .un   => |u| { if (@strEq(u.op, "try")) { rt_agg = 1; } }
                            else => { }
                        }
                    }
'''
new = '''                    if (rt_agg == 0) {
                        // A declared aggregate destination is copied from the address
                        // produced by aggregate-valued expressions. Coarse expression
                        // typing cannot always recover the concrete aggregate name, so
                        // admit only forms whose native lowering can produce an address.
                        switch (initexpr.*) {
                            .id      => |_id| { rt_agg = 1; }
                            .fld     => |_f| { rt_agg = 1; }
                            .idx     => |_x| { rt_agg = 1; }
                            .call    => |_c| { rt_agg = 1; }
                            .switch_ => |_s| { rt_agg = 1; }
                            .un      => |u| { if (@strEq(u.op, "try")) { rt_agg = 1; } }
                            else => { }
                        }
                    }
'''
if new not in text:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one aggregate-let gate, found {count}")
    source.write_text(text.replace(old, new, 1))

tests_path = Path("zag-poc/tests/run_native.sh")
tests = tests_path.read_text()
anchor = '''nt  "struct byval return" 'struct P { x: i32, y: i32 } fn mk(a: i32, b: i32) P { return P{ .x = a, .y = b }; } fn main() i32 { let p: P = mk(30, 12); return p.x + p.y; }' 42
'''
regression = '''nt  "aggregate let values" 'struct P { x: i32, y: i32 } struct H { first: P, second: P } enum Side { left, right } fn mk(a: i32, b: i32) P { return P{ .x = a, .y = b }; } fn copy(raw: P) P { let value: P = raw; return value; } fn field(raw: H) P { let value: P = raw.first; return value; } fn choose(side: Side) P { let value: P = switch (side) { .left => mk(10, 20), .right => mk(40, 2), }; return value; } fn main() i32 { let direct: P = mk(5, 7); let copied: P = copy(direct); let holder: H = H{ .first = mk(8, 9), .second = mk(1, 2) }; let selected: P = choose(Side.right); let from_field: P = field(holder); if (copied.x + copied.y != 12) { return 1; } if (from_field.x + from_field.y != 17) { return 2; } return selected.x + selected.y; }' 42
'''
if regression not in tests:
    count = tests.count(anchor)
    if count != 1:
        raise SystemExit(f"expected one native regression anchor, found {count}")
    tests_path.write_text(tests.replace(anchor, anchor + regression, 1))

for extra in [
    ".github/workflows/diagnose-v2-aggregate-let.yml",
    ".github/aggregate-let-experiment-failure.log",
    ".github/v2-aggregate-let-failure.log",
    ".github/repair_aggregate_let.py",
]:
    Path(extra).unlink(missing_ok=True)
