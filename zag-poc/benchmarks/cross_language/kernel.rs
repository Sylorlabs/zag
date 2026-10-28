fn main() {
    let mut x: i64 = 17;
    let mut checksum: i64 = 0;
    for _ in 0..__ITERATIONS__i64 {
        x = (x * 109 + 1021) % 65521;
        checksum = (checksum + x) % 1_000_000_007;
    }
    println!("{checksum}");
}
