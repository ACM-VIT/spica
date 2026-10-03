#ifndef SPICA_PROCESS_H
#define SPICA_PROCESS_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    int input, output, error, exit_fd, pid;
} SpicaProcess;
int spica_wake_create(int fds[2]);
void spica_wake(int fd);
void spica_close(int fd);
int spica_process_spawn(SpicaProcess *p, const char *node, const char *entry, const char *cwd,
                        const char *resume, int trust, const char *extension);
int spica_process_auth(SpicaProcess *p, const char *node, const char *entry, const char *cwd,
                       const char *helper);
/* A verifier that fails while still alive remains owned in p for explicit shutdown. */
int spica_process_version(SpicaProcess *p, const char *node, const char *entry);
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
