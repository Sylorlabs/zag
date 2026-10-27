fn main() {
    let mut x: i64 = 17;
    let mut checksum: i64 = 0;
    for _ in 0..__ITERATIONS__i64 {
        x = (x * 109 + 1021) % 65521;
        if x % 4 == 0 { checksum = (checksum + x * 7 + 3) % 1_000_000_007; }
        else if x % 4 == 1 { checksum = (checksum + x * 11 + 5) % 1_000_000_007; }
        else if x % 4 == 2 { checksum = (checksum + x * 13 + 7) % 1_000_000_007; }
        else { checksum = (checksum + x * 17 + 9) % 1_000_000_007; }
    }
    println!("{checksum}");
}
