#include <stdint.h>

extern int64_t zag_add_i64(int64_t, int64_t);

int main(void) {
    return zag_add_i64(19, 23) == 42 ? 42 : 1;
}
