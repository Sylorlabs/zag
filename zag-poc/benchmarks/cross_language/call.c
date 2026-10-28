#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
static int64_t advance(int64_t x) { return (x * 109 + 1021) % 65521; }
static int64_t accumulate(int64_t checksum, int64_t x) {
    return (checksum + x * 7 + 3) % 1000000007;
}
int main(void) {
    int64_t x = 17, checksum = 0;
    for (int64_t i = 0; i < __ITERATIONS__; ++i) {
        x = advance(x);
        checksum = accumulate(checksum, x);
    }
    printf("%" PRId64 "\n", checksum);
    return 0;
}
