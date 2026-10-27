#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
int main(void) {
    int64_t x = 17, checksum = 0;
    for (int64_t i = 0; i < __ITERATIONS__; ++i) {
        x = (x * 109 + 1021) % 65521;
        if (x % 4 == 0) checksum = (checksum + x * 7 + 3) % 1000000007;
        else if (x % 4 == 1) checksum = (checksum + x * 11 + 5) % 1000000007;
        else if (x % 4 == 2) checksum = (checksum + x * 13 + 7) % 1000000007;
        else checksum = (checksum + x * 17 + 9) % 1000000007;
    }
    printf("%" PRId64 "\n", checksum);
    return 0;
}
