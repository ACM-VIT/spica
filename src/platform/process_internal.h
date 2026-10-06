#ifndef SPICA_PROCESS_INTERNAL_H
#define SPICA_PROCESS_INTERNAL_H
/* Private C hooks called by process_posix.c, not the Zig-facing API in process.h.
 * build.zig links exactly one implementation: process_linux.c or process_macos.c. */

/* Create a blocking, close-on-exec pipe; caller owns both ends. Returns 0 or -1 with errno. */
int spica_process_pipe(int fds[2]);
/* Return a caller-owned, pollable exit descriptor, or -1 with errno. Does not reap the child. */
int spica_process_exit_watch(int pid);
/* Flags for a new session, signal defaults, and backend descriptor-inheritance rules. */
short spica_process_spawn_flags(void);
/* Requires an owned, unreaped child; exit_fd is a pidfd on Linux, unused on macOS.
 * Kill its owned tree without reaping or closing exit_fd. Returns 0 or -1 with errno. */
int spica_process_force_owned(int pid, int exit_fd);
#endif
