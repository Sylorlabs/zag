#include <stdint.h>

static int64_t *close_counter;

int64_t zag_plugin_apply(int64_t value) {
    return value * 2 + 2;
}

int64_t zag_plugin_watch_close(int64_t address) {
    close_counter = (int64_t *)(uintptr_t)address;
    return 7;
}

__attribute__((destructor)) static void zag_plugin_unloaded(void) {
    if (close_counter != 0) {
        *close_counter += 1;
    }
}
