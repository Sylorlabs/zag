#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
    uint64_t value;
    uint64_t checksum;
    uint64_t minimum;
    uint64_t maximum;
} State;

static uint64_t fold0(uint64_t x) { return (x + 17) % UINT64_C(1000000007); }
static uint64_t fold1(uint64_t x) { return (x * 3 + 5) % UINT64_C(1000000007); }
static uint64_t fold2(uint64_t x) { return (x ^ (x >> 7)) % UINT64_C(1000000007); }
static uint64_t fold3(uint64_t x) { return (x * 11 + 97) % UINT64_C(1000000007); }
static uint64_t fold4(uint64_t x) { return (x + (x >> 3) + 23) % UINT64_C(1000000007); }
static uint64_t fold5(uint64_t x) { return (x * 13 + 101) % UINT64_C(1000000007); }
static uint64_t fold6(uint64_t x) { return (x ^ (x << 5)) % UINT64_C(1000000007); }
static uint64_t fold7(uint64_t x) { return (x * 19 + 7) % UINT64_C(1000000007); }

static uint64_t mix(uint64_t x) {
    return fold7(fold6(fold5(fold4(fold3(fold2(fold1(fold0(x))))))));
}

static void advance(State *state) {
    state->value = (state->value * 48271 + 1) % UINT64_C(2147483647);
    uint64_t item = mix(state->value);
    state->checksum = (state->checksum + item) % UINT64_C(1000000007);
    if (item < state->minimum) state->minimum = item;
    if (item > state->maximum) state->maximum = item;
}

static uint64_t run(int32_t rounds) {
    State state = {UINT64_C(1234567), 0, UINT64_C(1000000007), 0};
    for (int32_t i = 0; i < rounds; ++i) advance(&state);
    return (state.checksum + state.minimum + state.maximum) % UINT64_C(1000000007);
}

int main(void) {
    uint64_t result = run(2000000);
    if (result != UINT64_C(115663923)) return 1;
    printf("%" PRIu64 "\n", result);
    return 0;
}
