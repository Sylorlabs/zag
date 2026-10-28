#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    int64_t x = 17;
    int64_t checksum = 0;
    for (int64_t i = 0; i < __ITERATIONS__; ++i) {
        x = (x * 109 + 1021) % 65521;
        checksum = (checksum + x) % 1000000007;
    }
    printf("%" PRId64 "\n", checksum);
    return 0;
}
