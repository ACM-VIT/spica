#define _GNU_SOURCE
#include "process.h"
#if defined(__linux__) || defined(__APPLE__)
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
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#ifdef __linux__
#include <sys/syscall.h>
#include <dirent.h>
#include <sys/stat.h>
#else
#include <sys/event.h>
#include <sys/proc.h>
#include <libproc.h>
#endif
extern char **environ;
#ifdef __linux__
static int pipes(int p[2]) { return pipe2(p, O_CLOEXEC); }
static int exit_watch(pid_t pid) { return (int)syscall(SYS_pidfd_open, pid, 0); }
#else
/* No pipe2: CLOEXEC is set after the fact, and POSIX_SPAWN_CLOEXEC_DEFAULT in spawn() keeps a pipe
 * created on another thread in that gap out of the child. */
static int pipes(int p[2]) {
    if (pipe(p))
        return -1;
    fcntl(p[0], F_SETFD, FD_CLOEXEC);
    fcntl(p[1], F_SETFD, FD_CLOEXEC);
    return 0;
}
/* No pidfd: a kqueue watching the child's exit stands in for it. Like a pidfd it is pollable and
 * stays readable once the child exits. Attaching to a child that already exited fails with ESRCH;
 * it is still unreaped and ours, so a user event is triggered to make the kqueue readable now. */
static int exit_watch(pid_t pid) {
    int kq = kqueue();
    if (kq < 0)
        return -1;
    struct kevent change;
    EV_SET(&change, pid, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, 0);
    int rc = kevent(kq, &change, 1, 0, 0, 0);
    if (rc < 0 && errno == ESRCH) {
        EV_SET(&change, 0, EVFILT_USER, EV_ADD, NOTE_TRIGGER, 0, 0);
        rc = kevent(kq, &change, 1, 0, 0, 0);
    }
    if (rc < 0) {
        int saved = errno;
        close(kq);
        errno = saved;
        return -1;
    }
    return kq;
}
#endif
static void nonblock(int fd) {
    int n = fcntl(fd, F_GETFL);
    if (n >= 0)
        fcntl(fd, F_SETFL, n | O_NONBLOCK);
}
int spica_wake_create(int fds[2]) {
    if (pipes(fds))
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
    if (pipes(in) || pipes(out) || pipes(err))
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
    short flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF;
#ifdef __APPLE__
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT; /* Only the three dup2'd descriptors reach the child. */
#endif
    posix_spawnattr_setflags(&attr, flags);
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
    *p = (SpicaProcess){in[1], out[0], err[0], exit_watch(pid), pid};
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
#ifdef __linux__
static int disappeared(void) { return errno == ENOENT || errno == ESRCH; }
static int pidfd_exited(int fd) {
    struct pollfd item = {fd, POLLIN, 0};
    int rc;
    do {
        rc = poll(&item, 1, 0);
    } while (rc < 0 && errno == EINTR);
    return rc > 0 && (item.revents & POLLIN);
}
static int proc_state(int pid, int *parent, char *state) {
    char path[64], bytes[4096];
    snprintf(path, sizeof path, "/proc/%d/stat", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t n;
    do {
        n = read(fd, bytes, sizeof(bytes) - 1);
    } while (n < 0 && errno == EINTR);
    int saved = errno;
    close(fd);
    errno = saved;
    if (n < 0)
        return -1;
    if (n == 0) {
        errno = EIO;
        return -1;
    }
    bytes[n] = 0;
    char *end = strrchr(bytes, ')');
    if (!end || sscanf(end + 2, "%c %d", state, parent) != 2) {
        errno = EIO;
        return -1;
    }
    return 0;
}
static int force_owned(int pid, int pidfd, int depth) {
    if (depth > 128) {
        errno = ELOOP;
        return -1;
    }
    if (syscall(SYS_pidfd_send_signal, pidfd, SIGSTOP, 0, 0) < 0)
        return errno == ESRCH ? 0 : -1;
    int parent;
    char state = 0;
    for (int i = 0; i < 100; i++) {
        if (proc_state(pid, &parent, &state) < 0) {
            int saved = errno;
            int gone = disappeared() && pidfd_exited(pidfd);
            errno = saved;
            return gone ? 0 : -1;
        }
        if (state == 'T' || state == 't' || state == 'Z')
            break;
        usleep(1000);
    }
    if (state != 'T' && state != 't' && state != 'Z') {
        errno = EBUSY;
        return -1;
    }
    char path[128];
    snprintf(path, sizeof path, "/proc/%d/task", pid);
    DIR *tasks = opendir(path);
    if (!tasks) {
        int saved = errno;
        int gone = disappeared() && pidfd_exited(pidfd);
        errno = saved;
        return gone ? 0 : -1;
    }
    FILE *children = 0;
    for (;;) {
        errno = 0;
        struct dirent *task = readdir(tasks);
        if (!task) {
            if (errno)
                goto fail;
            break;
        }
        char *end = 0;
        long tid = strtol(task->d_name, &end, 10);
        if (tid <= 0 || !end || *end)
            continue;
        snprintf(path, sizeof path, "/proc/%d/task/%ld/children", pid, tid);
        children = fopen(path, "re");
        if (!children) {
            int saved = errno;
            /* ENOENT is harmless only if that task actually disappeared. */
            struct stat metadata;
            if (disappeared() && fstatat(dirfd(tasks), task->d_name, &metadata, 0) < 0 &&
                errno == ENOENT)
                continue;
            errno = saved;
            goto fail;
        }
        for (;;) {
            int child;
            int parsed = fscanf(children, "%d", &child);
            if (parsed == EOF) {
                if (ferror(children)) {
                    if (!errno)
                        errno = EIO;
                    goto fail;
                }
                break;
            }
            if (parsed != 1 || child <= 0) {
                errno = EIO;
                goto fail;
            }
            int fd = (int)syscall(SYS_pidfd_open, child, 0);
            if (fd < 0) {
                if (errno == ESRCH)
                    continue;
                goto fail;
            }
            int owner = 0;
            char childstate = 0;
            /* Pin first, then prove parentage. A reused unrelated PID is never signaled. */
            int rc = proc_state(child, &owner, &childstate);
            if (rc < 0) {
                int saved = errno;
                int gone = disappeared() && pidfd_exited(fd);
                close(fd);
                errno = saved;
                if (gone)
                    continue;
                goto fail;
            }
            if (owner == pid && force_owned(child, fd, depth + 1) < 0) {
                int saved = errno;
                close(fd);
                errno = saved;
                goto fail;
            }
            close(fd);
        }
        if (fclose(children) < 0) {
            children = 0;
            goto fail;
        }
        children = 0;
    }
    if (closedir(tasks) < 0)
        return -1;
    /* Never release the parent while enumeration or an owned descendant failed. */
    return syscall(SYS_pidfd_send_signal, pidfd, SIGKILL, 0, 0) < 0 && errno != ESRCH ? -1 : 0;
fail: {
    int saved = errno;
    if (children)
        fclose(children);
    closedir(tasks);
    errno = saved;
    return -1;
}
}
#else
static int bsd_info(pid_t pid, struct proc_bsdinfo *info) {
    errno = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof *info) == (int)sizeof *info)
        return 0;
    if (!errno)
        errno = EIO;
    return -1;
}
/* No pidfds, so ownership rests on reaping: a PID cannot be reused until its parent reaps it. The
 * caller guarantees pid is unreaped (Spica never reaps before force, and a stopped parent cannot
 * reap), so ESRCH for it means it already exited. Stopping pid pins its children the same way. */
static int force_owned(pid_t pid, int depth) {
    if (depth > 128) {
        errno = ELOOP;
        return -1;
    }
    if (kill(pid, SIGSTOP) < 0)
        return errno == ESRCH ? 0 : -1;
    pid_t local[256], *children = local;
    int capacity = (int)(sizeof local / sizeof local[0]);
    int result = -1;
    struct proc_bsdinfo info;
    info.pbi_status = 0;
    for (int i = 0; i < 100; i++) {
        if (bsd_info(pid, &info) < 0) {
            if (errno == ESRCH)
                result = 0;
            goto done;
        }
        if (info.pbi_status == SSTOP || info.pbi_status == SZOMB)
            break;
        usleep(1000);
    }
    if (info.pbi_status != SSTOP && info.pbi_status != SZOMB) {
        errno = EBUSY;
        goto done;
    }
    /* The stopped parent cannot fork or reap. Grow only on overflow, retaining the common small
     * list on the stack. A full list may be truncated, so never kill from that snapshot. */
    int count;
    for (;;) {
        errno = 0;
        count = proc_listchildpids(pid, children, capacity * (int)sizeof(*children));
        if (count < 0 || (!count && errno))
            goto done;
        if (count < capacity)
            break;
        if (capacity > INT_MAX / (int)sizeof(*children) / 2) {
            errno = E2BIG;
            goto done;
        }
        int next = capacity * 2;
        pid_t *grown = malloc((size_t)next * sizeof(*children));
        if (!grown) {
            errno = ENOMEM;
            goto done;
        }
        if (children != local)
            free(children);
        children = grown;
        capacity = next;
    }
    for (int i = 0; i < count; i++) {
        struct proc_bsdinfo child;
        /* Prove parentage before signaling. ESRCH: it exited and stays unreaped by the stopped pid. */
        if (bsd_info(children[i], &child) < 0) {
            if (errno == ESRCH)
                continue;
            goto done;
        }
        if ((pid_t)child.pbi_ppid == pid && force_owned(children[i], depth + 1) < 0)
            goto done;
    }
    result = kill(pid, SIGKILL) < 0 && errno != ESRCH ? -1 : 0;
done: {
    int saved = errno;
    if (children != local)
        free(children);
    /* Failed enumeration/recursion must not strand the owned tree in SIGSTOP. Descendants resume
     * on their own failure before this unwinds; killed descendants remain pinned until reaped. */
    if (result < 0)
        kill(pid, SIGCONT);
    errno = saved;
    return result;
}
}
#endif
int spica_process_force(SpicaProcess *p) {
    if (p->pid <= 0)
        return 0;
    /* A failed initial pidfd_open must not make later explicit retries impossible. */
    if (p->exit_fd < 0) {
        int status;
        int reaped = spica_process_reap(p, &status);
        if (reaped == 1)
            return 0;
        if (reaped < 0)
            return -1; /* Never pin a possibly reused PID after ownership was lost. */
        p->exit_fd = exit_watch(p->pid);
        if (p->exit_fd < 0)
            return -1;
    }
#ifdef __linux__
    return force_owned(p->pid, p->exit_fd, 0);
#else
    return force_owned(p->pid, 0);
#endif
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
int spica_process_version(SpicaProcess *p, const char *node, const char *entry) {
    char *argv[] = {(char *)node, (char *)entry, "--version", 0};
    if (spawn(p, node, argv, "/"))
        return -1;
    spica_close(p->input);
    p->input = -1;
    char out[256];
    size_t n = 0;
    int result = -1, status = 0;
    long long deadline = ms() + 5000;
    for (;;) {
        struct pollfd f[3] = {
            {p->output, POLLIN, 0}, {p->error, POLLIN, 0}, {p->exit_fd, POLLIN, 0}};
        int left = (int)(deadline - ms());
        if (left <= 0)
            break;
        int rc = poll(f, 3, left);
        if (rc < 0 && errno == EINTR)
            continue;
        if (rc <= 0)
            break;
        if (f[0].revents) {
            char b[256];
            long r;
            while ((r = spica_process_read(p->output, b, sizeof b)) > 0) {
                size_t add = (size_t)r;
                if (add > sizeof(out) - n)
                    add = sizeof(out) - n;
                memcpy(out + n, b, add);
                n += add;
            }
        }
        if (f[1].revents) {
            char b[1024];
            while (spica_process_read(p->error, b, sizeof b) > 0) {
            }
        }
        if (f[2].revents) {
            int reaped = spica_process_reap(p, &status);
            if (reaped < 0)
                break;
            if (reaped == 1) {
                while (n < sizeof(out)) {
                    long r = spica_process_read(p->output, out + n, sizeof(out) - n);
                    if (r <= 0)
                        break;
                    n += (size_t)r;
                }
                result = WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
                                 ((n == 6 && out[5] == '\n') ||
                                  (n == 7 && out[5] == '\r' && out[6] == '\n')) &&
                                 !memcmp(out, "1.0.0", 5)
                             ? 0
                             : -1;
                break;
            }
        }
    }
    /* A timed-out verifier is still owned by the runtime; only explicit Force kills it. */
    if (p->pid == 0)
        spica_process_dispose(p);
    return result;
}
uint64_t spica_runtime_id(void) {
    uint64_t id = 0;
#ifdef __APPLE__
    arc4random_buf(&id, sizeof id);
#else
    ssize_t n;
    do {
        n = syscall(SYS_getrandom, &id, sizeof id, 0);
    } while (n < 0 && errno == EINTR);
    if (n != (ssize_t)sizeof id)
        return 0;
#endif
    id &= INT64_MAX;
    return id ? id : 1;
}
#else
int spica_wake_create(int f[2]) {
    (void)f;
    return -1;
}
void spica_wake(int f) { (void)f; }
void spica_close(int f) { (void)f; }
int spica_process_spawn(SpicaProcess *p, const char *n, const char *e, const char *c, const char *r,
                        int t) {
    (void)p;
    (void)n;
    (void)e;
    (void)c;
    (void)r;
    (void)t;
    return -1;
}
int spica_process_version(SpicaProcess *p, const char *n, const char *e) {
    (void)p;
    (void)n;
    (void)e;
    return -1;
}
int spica_process_poll(SpicaProcess *p, int w, int x, int t) {
    (void)p;
    (void)w;
    (void)x;
    (void)t;
    return -1;
}
long spica_process_read(int f, void *b, size_t n) {
    (void)f;
    (void)b;
    (void)n;
    return -1;
}
long spica_process_write(int f, const void *b, size_t n) {
    (void)f;
    (void)b;
    (void)n;
    return -1;
}
int spica_process_reap(SpicaProcess *p, int *s) {
    (void)p;
    (void)s;
    return -1;
}
int spica_process_force(SpicaProcess *p) {
    (void)p;
    return -1;
}
void spica_process_dispose(SpicaProcess *p) { (void)p; }
uint64_t spica_runtime_id(void) { return 1; }
uint64_t spica_monotonic_ms(void) { return 0; }
#endif
