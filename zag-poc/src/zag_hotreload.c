// zag_hotreload.c — Zag native runtime code-patching runtime.
//
// Linked into a `zagc build --hot` host executable. The generated C routes
// every Zag→Zag call through a per-function pointer (`__zag_fp_<name>`); this
// runtime owns the machinery to atomically re-aim those pointers at code loaded
// from a freshly compiled patch shared object — WITHOUT restarting the process,
// so all live program state (globals, heap, the stack of `main`) is retained.
//
// Honest boundary: patch granularity is a whole function via an atomic
// pointer swap performed at a safe point (the running loop checks a flag set by
// the signal handler, then reloads in normal context — dlopen is not
// async-signal-safe). For single-threaded programs the swap point is exactly
// safe; we do not literally rewrite machine code mid-instruction.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Provided by the generated C (the dispatch registry).
typedef struct { const char* sym; void** slot; } ZagHotEntry;
extern ZagHotEntry __zag_hot_entries[];
extern int __zag_hot_entry_count;

static char            g_patch_path[1024] = "./zag_patch.so";
static volatile sig_atomic_t g_reload_pending = 0;
static int             g_generation = 0;

// Copy src → dst (binary). Returns 0 on success. We reload through a fresh
// unique filename every generation because dlopen() caches by path: a patch
// .so rebuilt in place at the same path would otherwise return stale code.
static int copy_file(const char* src, const char* dst) {
    FILE* in = fopen(src, "rb");
    if (!in) return -1;
    FILE* out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }
    char buf[65536];
    size_t n;
    int rc = 0;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) { rc = -1; break; }
    }
    fclose(in);
    fclose(out);
    return rc;
}

// ── core: atomically re-aim every dispatch pointer at the patch .so ──────────
int zag_hot_reload(const char* sofile) {
    char tmp[1280];
    snprintf(tmp, sizeof tmp, "/tmp/zag_hot_%d_%d.so", (int)getpid(), g_generation + 1);
    if (copy_file(sofile, tmp) != 0) {
        fprintf(stderr, "[hot] cannot stage patch '%s': %s\n", sofile, strerror(errno));
        return -1;
    }
    void* h = dlopen(tmp, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "[hot] dlopen('%s') failed: %s\n", tmp, dlerror());
        return -1;
    }
    int rebound = 0;
    for (int i = 0; i < __zag_hot_entry_count; i++) {
        void* sym = dlsym(h, __zag_hot_entries[i].sym);
        if (sym) {
            // Pointer-width atomic store: the live function pointer flips here.
            __atomic_store_n(__zag_hot_entries[i].slot, sym, __ATOMIC_SEQ_CST);
            rebound++;
        }
    }
    g_generation++;
    fprintf(stderr, "[hot] generation %d: rebound %d/%d function(s) from %s\n",
            g_generation, rebound, __zag_hot_entry_count, sofile);
    return rebound;
}

// ── signal-driven reload: handler sets a flag; loop reloads at a safe point ──
static void on_sigusr1(int signo) {
    (void)signo;
    g_reload_pending = 1; // async-signal-safe: just a flag
}

__attribute__((constructor))
static void zag_hot_autostart(void) {
    const char* env = getenv("ZAG_HOT_PATCH");
    if (env && env[0]) {
        strncpy(g_patch_path, env, sizeof(g_patch_path) - 1);
        g_patch_path[sizeof(g_patch_path) - 1] = '\0';
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigusr1;
    sigaction(SIGUSR1, &sa, NULL);
    fprintf(stderr, "[hot] live: PID %d — `kill -USR1 %d` reloads %s\n",
            (int)getpid(), (int)getpid(), g_patch_path);
}

// ── externs the Zag program calls to drive a reloadable loop ─────────────────

// True until a `./zag_hot_stop` sentinel file appears (lets a demo end cleanly).
int zag_hot_should_continue(void) {
    return access("./zag_hot_stop", F_OK) != 0;
}

// One quantum of the run loop: applies a pending reload at this safe point,
// then sleeps ~300ms so an external patch+signal can land between iterations.
void zag_hot_wait(void) {
    if (g_reload_pending) {
        g_reload_pending = 0;
        zag_hot_reload(g_patch_path);
    }
    struct timespec ts = { 0, 300L * 1000L * 1000L };
    nanosleep(&ts, NULL);
}

// How many times code has been hot-swapped this run (observable from Zag).
int zag_hot_generation(void) {
    return g_generation;
}
