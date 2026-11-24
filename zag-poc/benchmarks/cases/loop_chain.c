// Standalone reference for benchmarks/cases/loop_chain.zag.
// This executable is never linked to Zag and is not a Zag runtime dependency.
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#define ITERATIONS UINT32_C(50000000)
#define EXPECTED UINT32_C(686528917)

int main(void) {
    uint32_t value = UINT32_C(123456789);
    uint32_t i = 0;
    while (i < ITERATIONS) {
        value = value * UINT32_C(1664525) + UINT32_C(1013904223);
        value = value & UINT32_C(2147483647);
        i = i + UINT32_C(1);
    }
    if (value != EXPECTED) return 1;
    printf("%" PRIu32 "\n", value);
    return 0;
}
