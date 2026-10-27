#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

typedef int64_t (*answer_fn)(void);
typedef answer_fn (*pointer_fn)(void);
typedef int (*pid_fn)(void);
typedef pid_fn (*pid_pointer_fn)(void);

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    for (int iteration = 0; iteration < 3; ++iteration) {
        void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 3; }
        answer_fn answer = (answer_fn)dlsym(lib, "zag_answer");
        pointer_fn pointer = (pointer_fn)dlsym(lib, "zag_answer_pointer");
        pointer_fn rebased = (pointer_fn)dlsym(lib, "zag_rebased_pointer");
        pid_fn pid = (pid_fn)dlsym(lib, "zag_pid");
        pid_pointer_fn bound = (pid_pointer_fn)dlsym(lib, "zag_bound_pointer");
        if (!answer || !pointer || !rebased || !pid || !bound) return 4;
        if (answer() != 42 || pointer() != answer || rebased() != answer ||
            pid() != getpid() || bound() != getpid || bound()() != getpid()) return 5;
        for (int i = 0; i < 300; ++i) {
            char name[64];
            snprintf(name, sizeof(name), "zag_export_%d", i);
            answer_fn alias = (answer_fn)dlsym(lib, name);
            if (alias != answer || alias() != 42) return 6;
        }
        if (dlsym(lib, "private_value") != NULL) return 7;
        if (dlclose(lib) != 0) return 8;
    }
    puts("dylib native loader: PASS 305 exports, data, function pointers, rebase/bind, getpid, repeated load/unload");
    return 0;
}
