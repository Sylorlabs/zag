#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long elapsed_ns(struct timespec start, struct timespec end) {
    return (long long)(end.tv_sec - start.tv_sec) * 1000000000LL +
        (long long)(end.tv_nsec - start.tv_nsec);
}

static long long timeval_us(struct timeval value) {
    return (long long)value.tv_sec * 1000000LL + value.tv_usec;
}

static void usage(const char *program) {
    fprintf(stderr, "usage: %s --output RESULT -- COMMAND [ARG...]\n", program);
}

int main(int argc, char **argv) {
    if (argc < 5 || strcmp(argv[1], "--output") != 0 ||
        strcmp(argv[3], "--") != 0) {
        usage(argv[0]);
        return 2;
    }

    struct timespec start;
    struct timespec end;
    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
        perror("clock_gettime(start)");
        return 2;
    }

    pid_t child = fork();
    if (child < 0) {
        perror("fork");
        return 2;
    }
    if (child == 0) {
        execvp(argv[4], &argv[4]);
        perror("execvp");
        _exit(127);
    }

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) continue;
        perror("waitpid");
        return 2;
    }
    if (clock_gettime(CLOCK_MONOTONIC, &end) != 0) {
        perror("clock_gettime(end)");
        return 2;
    }

    struct rusage usage_data;
    if (getrusage(RUSAGE_CHILDREN, &usage_data) != 0) {
        perror("getrusage");
        return 2;
    }

    int exit_status = 0;
    int term_signal = 0;
    if (WIFEXITED(status)) {
        exit_status = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        term_signal = WTERMSIG(status);
        exit_status = 128 + term_signal;
    } else {
        exit_status = 125;
    }

    FILE *result = fopen(argv[2], "w");
    if (result == NULL) {
        perror("fopen(result)");
        return 2;
    }
    fprintf(result, "%lld\t%lld\t%lld\t%ld\t%d\t%d\n",
        elapsed_ns(start, end), timeval_us(usage_data.ru_utime),
        timeval_us(usage_data.ru_stime), usage_data.ru_maxrss,
        exit_status, term_signal);
    if (fclose(result) != 0) {
        perror("fclose(result)");
        return 2;
    }
    return exit_status > 255 ? 255 : exit_status;
}
