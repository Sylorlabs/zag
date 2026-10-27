fn advance(x: i64) -> i64 { (x * 109 + 1021) % 65521 }
fn accumulate(checksum: i64, x: i64) -> i64 {
    (checksum + x * 7 + 3) % 1_000_000_007
}
fn main() {
    let mut x: i64 = 17;
    let mut checksum: i64 = 0;
    for _ in 0..__ITERATIONS__i64 {
        x = advance(x);
        checksum = accumulate(checksum, x);
    }
    println!("{checksum}");
}
