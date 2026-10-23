/* New-store durability only. No legacy path, import, database rename or migration. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <string.h>

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

/* Persist each newly reachable directory entry, including nested state paths.
 * The Zig caller supplies the absolute realpath; no cwd/environment lookup. */
int spica_store_sync_ancestry(const char *path) {
    char parent[PATH_MAX];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof(parent) || path[0] != '/') {
        errno = EINVAL;
        return -1;
    }
    memcpy(parent, path, n + 1);
    for (;;) {
        if (spica_store_sync_directory(parent) != 0)
            return -1;
        if (n == 1)
            return 0;
        while (n > 1 && parent[n - 1] != '/')
            --n;
        if (n > 1)
            --n;
        parent[n] = '\0';
    }
}
