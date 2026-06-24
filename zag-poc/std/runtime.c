/*
 * zag-poc/std/runtime.c — C bootstrap runtime for Zag's standard library
 *
 * Provides C implementations of stdlib primitives that cannot yet be expressed
 * in pure Zag (no varargs, no void pointers, no raw syscall surface).
 *
 * All symbols are prefixed _zag_ to avoid collisions with user or libc symbols.
 * Slice types mirror those in src/numeric_prelude.c and the Zig codegen.
 *
 * Effect annotations (comments only — enforcement is the compiler's job):
 *   _zag_malloc / _zag_realloc / _zag_free  : [Alloc]
 *   _zag_read_file / _zag_write_file         : [IO, Alloc]
 *   _zag_exec_cmd / _zag_exec_capture        : [Exec, IO, Alloc]
 *   _zag_str_*                               : [pure] (no alloc variants) or [Alloc]
 *   _zag_print_* / _zag_eprint_*             : [IO]
 */

/* Request POSIX.1-2008 extensions (popen, pclose, WIFEXITED, usleep, etc.) */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE   700

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <assert.h>
#include <sys/wait.h>

/* ── Zag ABI slice types ──────────────────────────────────────────────────── */

typedef struct { const uint8_t* ptr; int32_t len; } ZagSliceU8;
typedef struct { uint8_t*       ptr; int32_t len; } ZagSliceU8Mut;
typedef struct { const int32_t* ptr; int32_t len; } ZagSliceI32;
typedef struct { const float*   ptr; int32_t len; } ZagSliceF32;
typedef struct { const double*  ptr; int32_t len; } ZagSliceF64;

/* ── Internal helpers ────────────────────────────────────────────────────── */

/* Convert a ZagSliceU8 path to a heap-allocated NUL-terminated C string.
   Caller must free() the result. */
static char* _zag_slice_to_cstr(ZagSliceU8 s) {
    char* p = (char*)malloc((size_t)s.len + 1);
    if (!p) { fprintf(stderr, "zag: OOM in _zag_slice_to_cstr\n"); abort(); }
    memcpy(p, s.ptr, (size_t)s.len);
    p[s.len] = '\0';
    return p;
}

/* Wrap a NUL-terminated C string as a ZagSliceU8.
   The slice's ptr points into the original buffer — no allocation. */
static ZagSliceU8 _zag_cstr_to_slice(const char* s) {
    ZagSliceU8 r;
    r.ptr = (const uint8_t*)s;
    r.len = s ? (int32_t)strlen(s) : 0;
    return r;
}

/* ── Memory allocation — [Alloc] effect ─────────────────────────────────── */

void* _zag_malloc(int32_t n) {
    if (n <= 0) return NULL;
    void* p = malloc((size_t)n);
    if (!p) { fprintf(stderr, "zag: OOM (malloc %d)\n", n); abort(); }
    return p;
}

void* _zag_calloc(int32_t count, int32_t elem_size) {
    if (count <= 0 || elem_size <= 0) return NULL;
    void* p = calloc((size_t)count, (size_t)elem_size);
    if (!p) { fprintf(stderr, "zag: OOM (calloc %d*%d)\n", count, elem_size); abort(); }
    return p;
}

void* _zag_realloc(void* p, int32_t n) {
    if (n <= 0) { free(p); return NULL; }
    void* r = realloc(p, (size_t)n);
    if (!r) { fprintf(stderr, "zag: OOM (realloc %d)\n", n); abort(); }
    return r;
}

void _zag_free(void* p) { free(p); }

/* Allocate a zeroed ZagSliceU8Mut of `n` bytes. [Alloc] */
ZagSliceU8Mut _zag_alloc_slice(int32_t n) {
    ZagSliceU8Mut s;
    s.ptr = (uint8_t*)_zag_calloc(n, 1);
    s.len = n;
    return s;
}

/* Free a ZagSliceU8Mut previously allocated by _zag_alloc_slice. [Alloc] */
void _zag_free_slice(ZagSliceU8Mut s) { free(s.ptr); }

/* ── String utilities — mix of [pure] and [Alloc] ───────────────────────── */

/* [pure] — length of a Zag string slice */
int32_t _zag_strlen(ZagSliceU8 s) { return s.len; }

/* [pure] — byte-equal comparison, returns 1 if equal */
int32_t _zag_strcmp(ZagSliceU8 a, ZagSliceU8 b) {
    if (a.len != b.len) return 0;
    return memcmp(a.ptr, b.ptr, (size_t)a.len) == 0 ? 1 : 0;
}

/* [pure] — lexicographic compare: <0, 0, >0 */
int32_t _zag_strcmp_ord(ZagSliceU8 a, ZagSliceU8 b) {
    int32_t min_len = a.len < b.len ? a.len : b.len;
    int r = memcmp(a.ptr, b.ptr, (size_t)min_len);
    if (r != 0) return (int32_t)r;
    return a.len - b.len;
}

/* [Alloc] — heap-duplicate a slice (caller must _zag_free the .ptr) */
ZagSliceU8 _zag_strdup(ZagSliceU8 s) {
    char* buf = (char*)_zag_malloc(s.len + 1);
    memcpy(buf, s.ptr, (size_t)s.len);
    buf[s.len] = '\0';
    ZagSliceU8 r;
    r.ptr = (const uint8_t*)buf;
    r.len = s.len;
    return r;
}

/* [Alloc] — concatenate two slices into a new heap allocation */
ZagSliceU8 _zag_str_concat(ZagSliceU8 a, ZagSliceU8 b) {
    int32_t total = a.len + b.len;
    char* buf = (char*)_zag_malloc(total + 1);
    memcpy(buf, a.ptr, (size_t)a.len);
    memcpy(buf + a.len, b.ptr, (size_t)b.len);
    buf[total] = '\0';
    ZagSliceU8 r;
    r.ptr = (const uint8_t*)buf;
    r.len = total;
    return r;
}

/* [pure] — check if haystack starts with prefix */
int32_t _zag_str_starts_with(ZagSliceU8 haystack, ZagSliceU8 prefix) {
    if (prefix.len > haystack.len) return 0;
    return memcmp(haystack.ptr, prefix.ptr, (size_t)prefix.len) == 0 ? 1 : 0;
}

/* [pure] — check if haystack ends with suffix */
int32_t _zag_str_ends_with(ZagSliceU8 haystack, ZagSliceU8 suffix) {
    if (suffix.len > haystack.len) return 0;
    return memcmp(haystack.ptr + (haystack.len - suffix.len),
                  suffix.ptr, (size_t)suffix.len) == 0 ? 1 : 0;
}

/* [pure] — find first occurrence of byte `c` in slice; returns index or -1 */
int32_t _zag_str_index_of_byte(ZagSliceU8 s, uint8_t c) {
    for (int32_t i = 0; i < s.len; i++)
        if (s.ptr[i] == c) return i;
    return -1;
}

/* ── Integer/float to string conversions — [Alloc] ──────────────────────── */

ZagSliceU8 _zag_i64_to_str(int64_t v) {
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%lld", (long long)v);
    char* s = (char*)_zag_malloc(n + 1);
    memcpy(s, buf, (size_t)(n + 1));
    ZagSliceU8 r;
    r.ptr = (const uint8_t*)s;
    r.len = (int32_t)n;
    return r;
}

ZagSliceU8 _zag_u64_to_str(uint64_t v) {
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%llu", (unsigned long long)v);
    char* s = (char*)_zag_malloc(n + 1);
    memcpy(s, buf, (size_t)(n + 1));
    ZagSliceU8 r;
    r.ptr = (const uint8_t*)s;
    r.len = (int32_t)n;
    return r;
}

ZagSliceU8 _zag_f64_to_str(double v) {
    char buf[64];
    int n = snprintf(buf, sizeof(buf), "%g", v);
    char* s = (char*)_zag_malloc(n + 1);
    memcpy(s, buf, (size_t)(n + 1));
    ZagSliceU8 r;
    r.ptr = (const uint8_t*)s;
    r.len = (int32_t)n;
    return r;
}

/* [pure] — parse decimal integer; sets *ok=1 on success, 0 on error */
int64_t _zag_str_to_i64(ZagSliceU8 s, int32_t* ok) {
    if (s.len == 0) { if (ok) *ok = 0; return 0; }
    char* cstr = _zag_slice_to_cstr(s);
    char* end;
    errno = 0;
    int64_t v = (int64_t)strtoll(cstr, &end, 10);
    int valid = (errno == 0 && end == cstr + s.len);
    free(cstr);
    if (ok) *ok = valid ? 1 : 0;
    return v;
}

/* ── I/O — [IO] effect ───────────────────────────────────────────────────── */

/* Print a slice to stdout without a newline. [IO] */
void _zag_print(ZagSliceU8 s) {
    fwrite(s.ptr, 1, (size_t)s.len, stdout);
}

/* Print a slice to stdout with a trailing newline. [IO] */
void _zag_println(ZagSliceU8 s) {
    fwrite(s.ptr, 1, (size_t)s.len, stdout);
    putchar('\n');
}

/* Print a slice to stderr with a trailing newline. [IO] */
void _zag_eprintln(ZagSliceU8 s) {
    fwrite(s.ptr, 1, (size_t)s.len, stderr);
    fputc('\n', stderr);
}

/* Flush stdout. [IO] */
void _zag_flush(void) { fflush(stdout); }

/* ── File I/O — [IO, Alloc] effect ──────────────────────────────────────── */

/*
 * Read an entire file into a heap-allocated ZagSliceU8.
 * Returns a slice with len == -1 on error (caller checks).
 * The buffer is NUL-terminated for convenience but len does not include the NUL.
 * Caller must _zag_free the .ptr.
 */
ZagSliceU8 _zag_read_file(ZagSliceU8 path) {
    ZagSliceU8 err_result;
    err_result.ptr = NULL;
    err_result.len = -1;

    char* cpath = _zag_slice_to_cstr(path);
    FILE* f = fopen(cpath, "rb");
    free(cpath);
    if (!f) return err_result;

    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return err_result; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return err_result; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return err_result; }

    char* buf = (char*)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); fprintf(stderr, "zag: OOM reading file\n"); abort(); }

    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);

    buf[got] = '\0';
    ZagSliceU8 result;
    result.ptr = (const uint8_t*)buf;
    result.len = (int32_t)got;
    return result;
}

/*
 * Write content to a file (truncate/create).
 * Returns 0 on success, -1 on error.
 */
int32_t _zag_write_file(ZagSliceU8 path, ZagSliceU8 content) {
    char* cpath = _zag_slice_to_cstr(path);
    FILE* f = fopen(cpath, "wb");
    free(cpath);
    if (!f) return -1;

    size_t written = fwrite(content.ptr, 1, (size_t)content.len, f);
    int err = ferror(f);
    fclose(f);
    return (err || written != (size_t)content.len) ? -1 : 0;
}

/*
 * Append content to a file (creates if missing).
 * Returns 0 on success, -1 on error.
 */
int32_t _zag_append_file(ZagSliceU8 path, ZagSliceU8 content) {
    char* cpath = _zag_slice_to_cstr(path);
    FILE* f = fopen(cpath, "ab");
    free(cpath);
    if (!f) return -1;

    size_t written = fwrite(content.ptr, 1, (size_t)content.len, f);
    int err = ferror(f);
    fclose(f);
    return (err || written != (size_t)content.len) ? -1 : 0;
}

/*
 * Check whether a file exists and is readable.
 * Returns 1 if accessible, 0 otherwise.
 */
int32_t _zag_file_exists(ZagSliceU8 path) {
    char* cpath = _zag_slice_to_cstr(path);
    int r = (access(cpath, F_OK) == 0) ? 1 : 0;
    free(cpath);
    return r;
}

/* ── Process execution — [Exec, IO] effect ───────────────────────────────── */

/*
 * Run a shell command via system(3).
 * Returns the exit status (0 = success), or -1 on failure to launch.
 */
int32_t _zag_exec_cmd(ZagSliceU8 cmd) {
    char* ccmd = _zag_slice_to_cstr(cmd);
    int rc = system(ccmd);
    free(ccmd);
    if (rc == -1) return -1;
#if defined(_WIN32)
    return (int32_t)rc;
#else
    /* Extract exit code from wait-status on POSIX */
    if (WIFEXITED(rc)) return (int32_t)WEXITSTATUS(rc);
    return -1;
#endif
}

/*
 * Run a shell command and capture its stdout into a ZagSliceU8.
 * Returns a slice with len == -1 on failure.
 * Caller must _zag_free the .ptr.
 * [Exec, IO, Alloc]
 */
ZagSliceU8 _zag_exec_capture(ZagSliceU8 cmd) {
    ZagSliceU8 err_result;
    err_result.ptr = NULL;
    err_result.len = -1;

    char* ccmd = _zag_slice_to_cstr(cmd);
    FILE* pipe = popen(ccmd, "r");
    free(ccmd);
    if (!pipe) return err_result;

    /* Grow buffer dynamically */
    size_t cap = 4096, used = 0;
    char* buf = (char*)malloc(cap);
    if (!buf) { pclose(pipe); fprintf(stderr, "zag: OOM exec_capture\n"); abort(); }

    char tmp[1024];
    size_t got;
    while ((got = fread(tmp, 1, sizeof(tmp), pipe)) > 0) {
        if (used + got + 1 > cap) {
            while (used + got + 1 > cap) cap *= 2;
            char* nb = (char*)realloc(buf, cap);
            if (!nb) { free(buf); pclose(pipe); fprintf(stderr, "zag: OOM exec_capture grow\n"); abort(); }
            buf = nb;
        }
        memcpy(buf + used, tmp, got);
        used += got;
    }
    int rc = pclose(pipe);
    (void)rc;  /* status available if needed; not surfaced here */

    buf[used] = '\0';
    ZagSliceU8 result;
    result.ptr = (const uint8_t*)buf;
    result.len = (int32_t)used;
    return result;
}

/* ── Environment — [IO] effect ───────────────────────────────────────────── */

/*
 * Read an environment variable.
 * Returns a zero-length slice (len == 0, ptr == NULL) if not set.
 * The returned slice aliases the process environment — do not free.
 */
ZagSliceU8 _zag_getenv(ZagSliceU8 name) {
    char* cname = _zag_slice_to_cstr(name);
    const char* val = getenv(cname);
    free(cname);
    if (!val) {
        ZagSliceU8 empty;
        empty.ptr = NULL;
        empty.len = 0;
        return empty;
    }
    return _zag_cstr_to_slice(val);
}

/* ── Panic/assert — [Panic] effect ───────────────────────────────────────── */

/*
 * Hard abort with a message.  Called by Zag's runtime panic handler.
 * Never returns.
 */
_Noreturn void _zag_panic(ZagSliceU8 msg) {
    fprintf(stderr, "zag panic: ");
    fwrite(msg.ptr, 1, (size_t)msg.len, stderr);
    fputc('\n', stderr);
    fflush(stderr);
    abort();
}

/*
 * Assert with a message.  Evaluates to a no-op in release builds
 * (when NDEBUG is defined).  In debug builds terminates on failure.
 */
void _zag_assert(int32_t cond, ZagSliceU8 msg) {
#ifndef NDEBUG
    if (!cond) _zag_panic(msg);
#else
    (void)cond; (void)msg;
#endif
}

/* ── Misc bootstrap glue ─────────────────────────────────────────────────── */

/*
 * Sleep for `ms` milliseconds.  [IO]
 * Uses nanosleep on POSIX; falls back to usleep on older systems.
 */
#if defined(_POSIX_VERSION) && _POSIX_VERSION >= 199309L
#include <time.h>
void _zag_sleep_ms(int32_t ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}
#else
void _zag_sleep_ms(int32_t ms) {
    if (ms > 0) usleep((unsigned)(ms) * 1000u);
}
#endif

/*
 * Return a monotonic timestamp in nanoseconds.  [IO, pure-observable]
 * Wraps clock_gettime(CLOCK_MONOTONIC) on POSIX.
 */
#if defined(_POSIX_VERSION) && _POSIX_VERSION >= 199309L
#include <time.h>
int64_t _zag_monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * (int64_t)1000000000 + (int64_t)ts.tv_nsec;
}
#else
int64_t _zag_monotonic_ns(void) {
    return (int64_t)0;   /* stub on platforms without POSIX clocks */
}
#endif

/*
 * Return the current wall-clock time as Unix epoch seconds.  [IO]
 */
int64_t _zag_unix_time(void) { return (int64_t)time(NULL); }

/*
 * Exit the process.  [Exec]
 * Called by Zag's std.process.exit().
 */
_Noreturn void _zag_exit(int32_t code) { exit((int)code); }
