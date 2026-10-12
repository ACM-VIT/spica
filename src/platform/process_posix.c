/* Shared process.h implementation: spawn, I/O, polling, reaping, and timing.
 * Calls process_internal.h hooks supplied by the backend selected in build.zig. */
#define _GNU_SOURCE
#include "process.h"
#include "process_internal.h"
#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <pthread.h>
#include <errno.h>
#include <string.h>
extern char **environ;

static void nonblock(int fd) {
    int n = fcntl(fd, F_GETFL);
    if (n >= 0)
        fcntl(fd, F_SETFL, n | O_NONBLOCK);
}
int spica_wake_create(int fds[2]) {
    if (spica_process_pipe(fds))
        return -1;
    nonblock(fds[0]);
    nonblock(fds[1]);
    return 0;
}
void spica_wake(int fd) {
    char b = 1;
    (void)write(fd, &b, 1);
}
void spica_close(int fd) {
    if (fd >= 0)
        close(fd);
}
static int spawn(SpicaProcess *p, const char *node, char *const argv[], const char *cwd) {
    int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
    if (spica_process_pipe(in) || spica_process_pipe(out) || spica_process_pipe(err))
        goto fail;
    posix_spawn_file_actions_t acts;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&acts);
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_adddup2(&acts, in[0], 0);
    posix_spawn_file_actions_adddup2(&acts, out[1], 1);
    posix_spawn_file_actions_adddup2(&acts, err[1], 2);
    posix_spawn_file_actions_addchdir_np(&acts, cwd);
    /* A new session exclusively owns this tree; never signal the GUI's group. */
    posix_spawnattr_setflags(&attr, spica_process_spawn_flags());
    sigset_t defs;
    sigemptyset(&defs);
    sigaddset(&defs, SIGPIPE);
    posix_spawnattr_setsigdefault(&attr, &defs);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, node, &acts, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&acts);
    posix_spawnattr_destroy(&attr);
    if (rc) {
        errno = rc;
        goto fail;
    }
    close(in[0]);
    close(out[1]);
    close(err[1]);
    *p = (SpicaProcess){in[1], out[0], err[0], spica_process_exit_watch(pid), pid};
    int spawn_error = errno;
    nonblock(p->input);
    nonblock(p->output);
    nonblock(p->error);
    if (p->exit_fd < 0) {
        int saved = spawn_error;
        if (kill(-pid, SIGKILL) < 0 && errno != ESRCH)
            return -1;
        pid_t reaped;
        do {
            reaped = waitpid(pid, 0, 0);
        } while (reaped < 0 && errno == EINTR);
        if (reaped != pid)
            return -1; /* Keep the child and its descriptors owned on failure. */
        p->pid = 0;
        spica_process_dispose(p);
        errno = saved;
        return -1;
    }
    return 0;
fail:
    for (int i = 0; i < 2; i++) {
        spica_close(in[i]);
        spica_close(out[i]);
        spica_close(err[i]);
    }
    return -1;
}
int spica_process_spawn(SpicaProcess *p, const char *node, const char *entry, const char *cwd,
                        const char *resume, int trust) {
    char *argv[8];
    int n = 0;
    argv[n++] = (char *)node;
    argv[n++] = (char *)entry;
    argv[n++] = "--mode";
    argv[n++] = "rpc";
    argv[n++] = trust ? "--approve" : "--no-approve";
    if (resume) {
        argv[n++] = "--session";
        argv[n++] = (char *)resume;
    }
    argv[n] = 0;
    return spawn(p, node, argv, cwd);
}
long spica_process_read(int fd, void *b, size_t n) {
    ssize_t r;
    do {
        r = read(fd, b, n);
    } while (r < 0 && errno == EINTR);
    return r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? -2 : r;
}
long spica_process_write(int fd, const void *b, size_t n) {
    /* Block SIGPIPE in this worker only; EPIPE is surfaced as a protocol failure. */
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &set, 0);
    ssize_t r;
    do {
        r = write(fd, b, n);
    } while (r < 0 && errno == EINTR);
    return r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? -2 : r;
}
int spica_process_poll(SpicaProcess *p, int wake, int write_pending, int timeout_ms) {
    struct pollfd f[5] = {{wake, POLLIN, 0},
                          {p->output, POLLIN, 0},
                          {p->error, POLLIN, 0},
                          {write_pending ? p->input : -1, POLLOUT, 0},
                          {p->exit_fd, POLLIN, 0}};
    int r;
    do {
        r = poll(f, 5, timeout_ms);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
        return -1;
    int bits = 0;
    for (int i = 0; i < 5; i++)
        if (f[i].revents)
            bits |= 1 << i;
    return bits;
}
int spica_process_reap(SpicaProcess *p, int *status) {
    if (p->pid <= 0)
        return 1;
    pid_t r;
    do {
        r = waitpid(p->pid, status, WNOHANG);
    } while (r < 0 && errno == EINTR);
    if (r == p->pid) {
        p->pid = 0;
        return 1;
    }
    return r < 0 ? -1 : 0;
}
int spica_process_force(SpicaProcess *p) {
    if (p->pid <= 0)
        return 0;
    /* A failed initial exit watch must not make later explicit retries impossible. */
    if (p->exit_fd < 0) {
        int status;
        int reaped = spica_process_reap(p, &status);
        if (reaped == 1)
            return 0;
        if (reaped < 0)
            return -1; /* Never pin a possibly reused PID after ownership was lost. */
        p->exit_fd = spica_process_exit_watch(p->pid);
        if (p->exit_fd < 0)
            return -1;
    }
    return spica_process_force_owned(p->pid, p->exit_fd);
}
void spica_process_dispose(SpicaProcess *p) {
    spica_close(p->input);
    spica_close(p->output);
    spica_close(p->error);
    spica_close(p->exit_fd);
    p->input = p->output = p->error = p->exit_fd = -1;
}
static long long ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
uint64_t spica_monotonic_ms(void) { return (uint64_t)ms(); }
static void capture_stdout(SpicaProcess *p, char *out, size_t capacity, size_t *n, int *overflow) {
    /* Bound each drain so continuous output cannot bypass the deadline. */
    for (int i = 0; i < 64; i++) {
        char b[1024];
        long r = spica_process_read(p->output, b, sizeof b);
        if (r <= 0)
            break;
        size_t add = (size_t)r;
        if (add > capacity - *n) {
            add = capacity - *n;
            *overflow = 1;
        }
        memcpy(out + *n, b, add);
        *n += add;
    }
}
static void capture_stderr(SpicaProcess *p, char *tail, size_t capacity, size_t *n, int *truncated) {
    for (int i = 0; i < 64; i++) {
        char b[1024];
        long r = spica_process_read(p->error, b, sizeof b);
        if (r <= 0)
            break;
        if (!tail || !capacity)
            continue;
        size_t add = (size_t)r;
        const char *from = b;
        if (add >= capacity) {
            from += add - capacity;
            add = capacity;
            *n = 0;
            *truncated = 1;
        } else if (add > capacity - *n) {
            size_t drop = add - (capacity - *n);
            memmove(tail, tail + drop, *n - drop);
            *n -= drop;
            *truncated = 1;
        }
        memcpy(tail + *n, from, add);
        *n += add;
    }
}
static int capture(SpicaProcess *p, const char *node, char *const argv[], int timeout_ms, char *out,
                   size_t capacity, size_t *length, int *wait_status, char *tail,
                   size_t tail_capacity, size_t *tail_length, int *tail_truncated) {
    *length = 0;
    if (spawn(p, node, argv, "/"))
        return SPICA_PROCESS_SPAWN_FAILED;
    spica_close(p->input);
    p->input = -1;
    size_t n = 0;
    int result = SPICA_PROCESS_TIMED_OUT, status = 0, overflow = 0;
    long long deadline = ms() + timeout_ms;
    for (;;) {
        struct pollfd f[3] = {
            {p->output, POLLIN, 0}, {p->error, POLLIN, 0}, {p->exit_fd, POLLIN, 0}};
        int left = (int)(deadline - ms());
        if (left <= 0)
            break;
        int rc = poll(f, 3, left);
        if (rc < 0 && errno == EINTR)
            continue;
        if (rc < 0)
            result = SPICA_PROCESS_WAIT_FAILED;
        if (rc <= 0)
            break;
        if (f[0].revents)
            capture_stdout(p, out, capacity, &n, &overflow);
        if (f[1].revents)
            capture_stderr(p, tail, tail_capacity, tail_length, tail_truncated);
        if (f[2].revents) {
            int reaped = spica_process_reap(p, &status);
            if (reaped < 0) {
                result = SPICA_PROCESS_WAIT_FAILED;
                break;
            }
            if (reaped == 1) {
                capture_stdout(p, out, capacity, &n, &overflow);
                capture_stderr(p, tail, tail_capacity, tail_length, tail_truncated);
                if (wait_status)
                    *wait_status = status;
                result = !(WIFEXITED(status) && WEXITSTATUS(status) == 0) ? SPICA_PROCESS_EXIT_FAILED
                         : overflow                                       ? SPICA_PROCESS_OUTPUT_OVERFLOW
                                                                          : SPICA_PROCESS_OK;
                break;
            }
        }
    }
    /* A timed-out verifier is still owned by the runtime; only explicit Force kills it. */
    if (p->pid == 0)
        spica_process_dispose(p);
    *length = n;
    return result;
}
int spica_process_version(SpicaProcess *p, const char *node, const char *entry, int timeout_ms,
                          SpicaVersionCheck *check) {
    char *argv[] = {(char *)node, (char *)entry, "--version", 0};
    char *out = check->output;
    int status = -1;
    check->output_length = 0;
    check->stderr_length = 0;
    check->stderr_truncated = 0;
    check->exit_code = -1;
    check->signal = 0;
    int result = capture(p, node, argv, timeout_ms, out, sizeof check->output, &check->output_length,
                         &status, check->stderr_tail, sizeof check->stderr_tail,
                         &check->stderr_length, &check->stderr_truncated);
    size_t n = check->output_length;
    if (status != -1 && WIFEXITED(status))
        check->exit_code = WEXITSTATUS(status);
    if (status != -1 && WIFSIGNALED(status))
        check->signal = WTERMSIG(status);
    if (result)
        return result;
    size_t v = sizeof SPICA_PI_VERSION - 1;
    return ((n == v + 1 && out[v] == '\n') || (n == v + 2 && out[v] == '\r' && out[v + 1] == '\n')) &&
                   !memcmp(out, SPICA_PI_VERSION, v)
               ? SPICA_PROCESS_OK
               : SPICA_PROCESS_VERSION_MISMATCH;
}
int spica_process_npm_root(SpicaProcess *p, const char *node, const char *npm, char *output,
                           size_t capacity, size_t *length) {
    /* npm is its resolved JS entry, not a shell command; Finder need not expose node on PATH. */
    char *argv[] = {(char *)node, (char *)npm, "root", "-g", "--loglevel=error", 0};
    size_t ignored_length = 0;
    int ignored_truncated = 0;
    return capture(p, node, argv, 5000, output, capacity, length, 0, 0, 0, &ignored_length,
                   &ignored_truncated);
}
