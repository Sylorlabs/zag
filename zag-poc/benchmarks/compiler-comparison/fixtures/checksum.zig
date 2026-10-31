const std = @import("std");

const State = struct {
    value: u64,
    checksum: u64,
    minimum: u64,
    maximum: u64,
};

fn fold0(x: u64) u64 { return (x + 17) % 1_000_000_007; }
fn fold1(x: u64) u64 { return (x * 3 + 5) % 1_000_000_007; }
fn fold2(x: u64) u64 { return (x ^ (x >> 7)) % 1_000_000_007; }
fn fold3(x: u64) u64 { return (x * 11 + 97) % 1_000_000_007; }
fn fold4(x: u64) u64 { return (x + (x >> 3) + 23) % 1_000_000_007; }
fn fold5(x: u64) u64 { return (x * 13 + 101) % 1_000_000_007; }
fn fold6(x: u64) u64 { return (x ^ (x << 5)) % 1_000_000_007; }
fn fold7(x: u64) u64 { return (x * 19 + 7) % 1_000_000_007; }

fn mix(x: u64) u64 {
    return fold7(fold6(fold5(fold4(fold3(fold2(fold1(fold0(x))))))));
}

fn advance(state: *State) void {
    state.value = (state.value * 48_271 + 1) % 2_147_483_647;
    const item = mix(state.value);
    state.checksum = (state.checksum + item) % 1_000_000_007;
    if (item < state.minimum) state.minimum = item;
    if (item > state.maximum) state.maximum = item;
}

fn run(rounds: u32) u64 {
    var state = State{
        .value = 1_234_567,
        .checksum = 0,
        .minimum = 1_000_000_007,
        .maximum = 0,
    };
    var i: u32 = 0;
    while (i < rounds) : (i += 1) advance(&state);
    return (state.checksum + state.minimum + state.maximum) % 1_000_000_007;
}

pub fn main() !void {
    const result = run(2_000_000);
    if (result != 115_663_923) return error.ChecksumMismatch;
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d}\n", .{result});
}
