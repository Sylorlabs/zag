// Standalone reference for benchmarks/cases/loop_chain.zag.
// This executable is never linked to Zag and is not a Zag runtime dependency.
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#define ITERATIONS UINT32_C(50000000)
#define MASK UINT32_C(16777215)
#define EXPECTED UINT32_C(14333703)

int main(void) {
    uint32_t value = UINT32_C(1234567);
    uint32_t i = 0;
    while (i < ITERATIONS) {
        value = value * UINT32_C(33) + UINT32_C(17);
        value = value & MASK;
        i = i + UINT32_C(1);
    }
    if (value != EXPECTED) return 1;
    printf("%" PRIu32 "\n", value);
    return 0;
}
