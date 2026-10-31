#include <cstdint>
#include <cstdio>

struct State {
    std::uint64_t value;
    std::uint64_t checksum;
    std::uint64_t minimum;
    std::uint64_t maximum;
};

static std::uint64_t fold0(std::uint64_t x) { return (x + 17) % UINT64_C(1000000007); }
static std::uint64_t fold1(std::uint64_t x) { return (x * 3 + 5) % UINT64_C(1000000007); }
static std::uint64_t fold2(std::uint64_t x) { return (x ^ (x >> 7)) % UINT64_C(1000000007); }
static std::uint64_t fold3(std::uint64_t x) { return (x * 11 + 97) % UINT64_C(1000000007); }
static std::uint64_t fold4(std::uint64_t x) { return (x + (x >> 3) + 23) % UINT64_C(1000000007); }
static std::uint64_t fold5(std::uint64_t x) { return (x * 13 + 101) % UINT64_C(1000000007); }
static std::uint64_t fold6(std::uint64_t x) { return (x ^ (x << 5)) % UINT64_C(1000000007); }
static std::uint64_t fold7(std::uint64_t x) { return (x * 19 + 7) % UINT64_C(1000000007); }

static std::uint64_t mix(std::uint64_t x) {
    return fold7(fold6(fold5(fold4(fold3(fold2(fold1(fold0(x))))))));
}

static void advance(State &state) {
    state.value = (state.value * 48271 + 1) % UINT64_C(2147483647);
    const std::uint64_t item = mix(state.value);
    state.checksum = (state.checksum + item) % UINT64_C(1000000007);
    if (item < state.minimum) state.minimum = item;
    if (item > state.maximum) state.maximum = item;
}

static std::uint64_t run(std::int32_t rounds) {
    State state{UINT64_C(1234567), 0, UINT64_C(1000000007), 0};
    for (std::int32_t i = 0; i < rounds; ++i) advance(state);
    return (state.checksum + state.minimum + state.maximum) % UINT64_C(1000000007);
}

int main() {
    const std::uint64_t result = run(2000000);
    if (result != UINT64_C(115663923)) return 1;
    std::printf("%llu\n", static_cast<unsigned long long>(result));
    return 0;
}
