/* New-store durability only. No legacy path, import, database rename or migration. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

int spica_store_sync_directory(const char *path) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    int rc;
    do {
        rc = fsync(fd);
    } while (rc < 0 && errno == EINTR);
    int saved = errno;
    int closed = close(fd);
    if (rc < 0) {
        errno = saved;
        return -1;
    }
    return closed;
}
