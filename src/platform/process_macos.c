/* macOS backend: private process_internal.h hooks and public runtime ID generation.
 * Linked with process_posix.c; uses kqueue and libproc for watching and stopping owned trees. */
#include "process.h"
#include "process_internal.h"
#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/event.h>
#include <sys/proc.h>
#include <libproc.h>

/* No pipe2: CLOEXEC is set after the fact, and POSIX_SPAWN_CLOEXEC_DEFAULT in spawn() keeps a pipe
 * created on another thread in that gap out of the child. */
int spica_process_pipe(int p[2]) {
    if (pipe(p))
        return -1;
    fcntl(p[0], F_SETFD, FD_CLOEXEC);
    fcntl(p[1], F_SETFD, FD_CLOEXEC);
    return 0;
}
/* No pidfd: a kqueue watching the child's exit stands in for it. Like a pidfd it is pollable and
 * stays readable once the child exits. Attaching to a child that already exited fails with ESRCH;
 * it is still unreaped and ours, so a user event is triggered to make the kqueue readable now. */
int spica_process_exit_watch(int pid) {
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
short spica_process_spawn_flags(void) {
    /* Only the three dup2'd descriptors reach the child. */
    return POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT;
}

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
        /* Prove parentage before signaling. ESRCH means it exited and stays unreaped by
         * the stopped parent. */
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
int spica_process_force_owned(int pid, int exit_fd) {
    (void)exit_fd;
    return force_owned(pid, 0);
}

uint64_t spica_runtime_id(void) {
    uint64_t id = 0;
    arc4random_buf(&id, sizeof id);
    id &= INT64_MAX;
    return id ? id : 1;
}
