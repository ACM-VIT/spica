/* Deterministic macOS force-stop probes; never signal a real process. */
#include <stdlib.h>
#include <signal.h>
#include <errno.h>
#include <libproc.h>
#include <sys/proc.h>
#include <string.h>

#define ROOT_PID 1000000
#define CHILDREN 300
static int stopped[CHILDREN + 1], killed[CHILDREN + 1];
static int allocation_failure, enumeration_failure, grew;

static int probe_kill(pid_t pid, int signal) {
    int index = pid - ROOT_PID;
    if (index < 0 || index > CHILDREN)
        abort();
    if (signal == SIGSTOP)
        stopped[index] = 1;
    else if (signal == SIGCONT)
        stopped[index] = 0;
    else if (signal == SIGKILL)
        killed[index] = 1;
    return 0;
}
static int probe_info(int pid, int flavor, uint64_t arg, void *buffer, int size) {
    (void)flavor;
    (void)arg;
    (void)size;
    struct proc_bsdinfo *info = buffer;
    memset(info, 0, sizeof(*info));
    info->pbi_ppid = pid == ROOT_PID ? 1 : ROOT_PID;
    info->pbi_status = killed[pid - ROOT_PID] ? SZOMB : stopped[pid - ROOT_PID] ? SSTOP : SRUN;
    return sizeof(*info);
}
static int probe_list(pid_t pid, void *buffer, int size) {
    if (pid == enumeration_failure) {
        errno = EIO;
        return 0; /* libproc can return zero with errno on failure. */
    }
    if (pid != ROOT_PID)
        return 0;
    int capacity = size / (int)sizeof(pid_t);
    grew |= capacity > 256;
    int count = capacity < CHILDREN ? capacity : CHILDREN;
    for (int i = 0; i < count; ++i)
        ((pid_t *)buffer)[i] = ROOT_PID + i + 1;
    return count;
}
static void *probe_malloc(size_t size) {
    return allocation_failure ? NULL : malloc(size);
}

#define kill probe_kill
#define proc_pidinfo probe_info
#define proc_listchildpids probe_list
#define malloc probe_malloc
#include "process.c"

static void reset(void) {
    memset(stopped, 0, sizeof(stopped));
    memset(killed, 0, sizeof(killed));
    allocation_failure = enumeration_failure = grew = 0;
}
int main(void) {
    reset();
    if (force_owned(ROOT_PID, 0) || !grew)
        return 1;
    for (int i = 0; i <= CHILDREN; ++i)
        if (!killed[i])
            return 2;
    reset();
    allocation_failure = 1;
    if (force_owned(ROOT_PID, 0) != -1 || errno != ENOMEM || stopped[0] || killed[0])
        return 3;
    allocation_failure = 0;
    if (force_owned(ROOT_PID, 0))
        return 4;
    reset();
    enumeration_failure = ROOT_PID + 1;
    if (force_owned(ROOT_PID, 0) != -1 || errno != EIO)
        return 5;
    for (int i = 0; i <= CHILDREN; ++i)
        if (stopped[i] || killed[i])
            return 6;
    enumeration_failure = 0;
    return force_owned(ROOT_PID, 0) ? 7 : 0;
}
