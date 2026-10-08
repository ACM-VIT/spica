#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/* Nonblocking open prevents named pipes from stalling the shared worker.
 * Validate the opened handle, then Zig reads that same handle (no reopen race). */
int spica_attachment_open(const char *path) {
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return errno == ENOENT ? -3 : -1;
    struct stat info;
    if (fstat(fd, &info) != 0) {
        close(fd);
        return -1;
    }
    if (!S_ISREG(info.st_mode)) {
        close(fd);
        return -2;
    }
    return fd;
}
