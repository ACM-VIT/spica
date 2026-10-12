#ifndef SPICA_PROCESS_H
#define SPICA_PROCESS_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    int input, output, error, exit_fd, pid;
} SpicaProcess;
#define SPICA_PI_VERSION "1.0.0"
#define SPICA_PI_VERIFY_TIMEOUT_MS 5000
typedef struct {
    char output[256];
    size_t output_length;
    char stderr_tail[4096];
    size_t stderr_length;
    int stderr_truncated;
    int exit_code, signal;
} SpicaVersionCheck;
enum {
    SPICA_PROCESS_OK = 0,
    SPICA_PROCESS_SPAWN_FAILED = -1,
    SPICA_PROCESS_EXIT_FAILED = -2,
    SPICA_PROCESS_TIMED_OUT = -3,
    SPICA_PROCESS_OUTPUT_OVERFLOW = -4,
    SPICA_PROCESS_WAIT_FAILED = -5,
    SPICA_PROCESS_VERSION_MISMATCH = -6,
};
int spica_wake_create(int fds[2]);
void spica_wake(int fd);
void spica_close(int fd);
int spica_process_spawn(SpicaProcess *p, const char *node, const char *entry, const char *cwd,
                        const char *resume, int trust);
/* A verifier that fails while still alive remains owned in p for explicit shutdown. */
int spica_process_version(SpicaProcess *p, const char *node, const char *entry, int timeout_ms,
                          SpicaVersionCheck *check);
/* Bounded, five-second global npm lookup, run with the resolved Node executable.
 * A failed lookup still alive remains owned in p, just like the version verifier. */
int spica_process_npm_root(SpicaProcess *p, const char *node, const char *npm, char *output,
                           size_t capacity, size_t *length);
/* bits: wake=1 stdout=2 stderr=4 writable=8 exited=16 */
int spica_process_poll(SpicaProcess *p, int wake, int want_write, int timeout_ms);
long spica_process_read(int fd, void *bytes, size_t size);
long spica_process_write(int fd, const void *bytes, size_t size);
int spica_process_reap(SpicaProcess *p, int *status);
/* On failure no ancestor is killed; p remains owned and explicit retry is allowed. */
int spica_process_force(SpicaProcess *p);
void spica_process_dispose(SpicaProcess *p);
uint64_t spica_runtime_id(void);
uint64_t spica_monotonic_ms(void);
#endif
