/* Linux backend: private process_internal.h hooks and public runtime ID generation.
 * Linked with process_posix.c; uses pidfds and /proc for watching and stopping owned trees. */
#define _GNU_SOURCE
#include "process.h"
#include "process_internal.h"
#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <dirent.h>
#include <sys/stat.h>

int spica_process_pipe(int p[2]) { return pipe2(p, O_CLOEXEC); }
int spica_process_exit_watch(int pid) { return (int)syscall(SYS_pidfd_open, pid, 0); }
short spica_process_spawn_flags(void) { return POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF; }

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
int spica_process_force_owned(int pid, int exit_fd) { return force_owned(pid, exit_fd, 0); }

uint64_t spica_runtime_id(void) {
    uint64_t id = 0;
    ssize_t n;
    do {
        n = syscall(SYS_getrandom, &id, sizeof id, 0);
    } while (n < 0 && errno == EINTR);
    if (n != (ssize_t)sizeof id)
        return 0;
    id &= INT64_MAX;
    return id ? id : 1;
}
