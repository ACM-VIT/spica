#include <sqlite3.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

static int validate(sqlite3 *database) {
    sqlite3_stmt *statement = NULL;
    int rc = sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, NULL);
    if (rc == SQLITE_OK) {
        if (sqlite3_step(statement) != SQLITE_ROW ||
            strcmp((const char *)sqlite3_column_text(statement, 0), "ok"))
            rc = SQLITE_CORRUPT;
    }
    int final = sqlite3_finalize(statement);
    if (rc == SQLITE_OK)
        rc = final;
    statement = NULL;
    if (rc == SQLITE_OK)
        rc = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, NULL);
    if (rc == SQLITE_OK &&
        (sqlite3_step(statement) != SQLITE_ROW || sqlite3_column_int(statement, 0) > 6))
        rc = SQLITE_ERROR;
    final = sqlite3_finalize(statement);
    return rc == SQLITE_OK ? final : rc;
}

static int discard_staging(const char *temporary) {
    char sidecar[8192];
    const char *suffixes[] = {"", "-wal", "-shm", "-journal"};
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); ++i) {
        int length = snprintf(sidecar, sizeof(sidecar), "%s%s", temporary, suffixes[i]);
        if (length < 0 || (size_t)length >= sizeof(sidecar))
            return SQLITE_CANTOPEN;
        if (remove(sidecar) != 0 && errno != ENOENT)
            return SQLITE_IOERR_DELETE;
    }
    return SQLITE_OK;
}

/* Bind helpers for Zig callers (store.zig, search_sql.zig). They live in C, not Zig, because
 * Zig cannot pass SQLITE_TRANSIENT on aarch64.
 *
 * SQLITE_TRANSIENT tells SQLite to copy the bytes before the bind call returns, so the caller's
 * slice only has to live for the duration of the call. SQLite defines it as
 * ((sqlite3_destructor_type)-1): an all-ones sentinel in a function-pointer slot that SQLite
 * compares against but never calls.
 *
 * @cImport does not bring that macro over, so the Zig code used to rebuild it with
 * @ptrFromInt(maxInt(usize)). Zig checks that an address converted to a function pointer meets
 * the target's code alignment. x86_64 needs 1 byte, so the all-ones address compiled there;
 * aarch64 needs 4, so Zig rejects it ("requires aligned address") and the build fails on Apple
 * Silicon and ARM Linux. C performs no such check, so these wrappers use SQLite's own macro and
 * pass exactly the value SQLite expects, with the same code on every architecture. */
int spica_database_bind_text(sqlite3_stmt *statement, int index, const char *text, int length) {
    return sqlite3_bind_text(statement, index, text, length, SQLITE_TRANSIENT);
}

int spica_database_bind_blob(sqlite3_stmt *statement, int index, const void *data, int length) {
    return sqlite3_bind_blob(statement, index, data, length, SQLITE_TRANSIENT);
}

/* Called under the application instance lock. Legacy files are never modified. */
int spica_database_cutover(const char *destination, const char *legacy, const char *temporary,
                           const char *directory) {
    sqlite3 *source = NULL, *target = NULL;
    sqlite3_backup *backup = NULL;
    int rc = SQLITE_OK;
    FILE *probe = fopen(destination, "rb");
    if (probe) {
        fclose(probe);
#ifdef __APPLE__
        /* Read-write on macOS, though validation only reads: the app keeps this database in WAL
         * mode, and a read-only connection must create the -wal/-shm files when a clean close has
         * removed them. macOS's SQLite refuses that (SQLITE_CANTOPEN), so every launch after the
         * first failed. This is Spica's own file and the store opens it read-write right after. */
        rc = sqlite3_open_v2(destination, &target, SQLITE_OPEN_READWRITE, NULL);
#else
        rc = sqlite3_open_v2(destination, &target, SQLITE_OPEN_READONLY, NULL);
#endif
        if (rc == SQLITE_OK)
            rc = validate(target);
        if (target && sqlite3_close(target) != SQLITE_OK && rc == SQLITE_OK)
            rc = SQLITE_BUSY;
        return rc;
    }
    if (errno != ENOENT)
        return SQLITE_CANTOPEN;
    probe = fopen(legacy, "rb");
    if (!probe)
        return errno == ENOENT ? SQLITE_OK : SQLITE_CANTOPEN;
    fclose(probe);
    /* An interrupted staging file is disposable, never authoritative. */
    rc = discard_staging(temporary);
    if (rc != SQLITE_OK)
        return rc;
#ifdef __APPLE__
    /* Read-write on macOS for the same reason as the destination above: a legacy database left in
     * WAL mode without its -wal/-shm files cannot be opened read-only by macOS's SQLite
     * (SQLITE_CANTOPEN), which would fail the migration. Only validate() and the backup read it, so
     * its data is not changed; SQLite may create -wal/-shm beside it and removes them on close. */
    rc = sqlite3_open_v2(legacy, &source, SQLITE_OPEN_READWRITE, NULL);
#else
    rc = sqlite3_open_v2(legacy, &source, SQLITE_OPEN_READONLY, NULL);
#endif
    if (rc != SQLITE_OK)
        goto done;
    rc = validate(source);
    if (rc != SQLITE_OK)
        goto done;
    rc = sqlite3_open_v2(temporary, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc != SQLITE_OK)
        goto done;
    rc = sqlite3_exec(target, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL", NULL, NULL,
                      NULL);
    if (rc != SQLITE_OK)
        goto done;
    backup = sqlite3_backup_init(target, "main", source, "main");
    if (!backup) {
        rc = sqlite3_errcode(target);
        goto done;
    }
    do {
        rc = sqlite3_backup_step(backup, 128);
    } while (rc == SQLITE_OK);
    {
        int finish = sqlite3_backup_finish(backup);
        backup = NULL;
        if (rc == SQLITE_DONE)
            rc = finish;
    }
    if (rc == SQLITE_OK)
        rc = sqlite3_exec(target, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL", NULL, NULL,
                          NULL);
    if (rc == SQLITE_OK)
        rc = validate(target);
done:
    if (backup)
        sqlite3_backup_finish(backup);
    if (target && sqlite3_close(target) != SQLITE_OK && rc == SQLITE_OK)
        rc = SQLITE_BUSY;
    if (source && sqlite3_close(source) != SQLITE_OK && rc == SQLITE_OK)
        rc = SQLITE_BUSY;
    if (rc != SQLITE_OK)
        return rc;
#ifdef _WIN32
    HANDLE file = CreateFileA(temporary, GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return SQLITE_IOERR_FSYNC;
    BOOL flushed = FlushFileBuffers(file);
    BOOL closed = CloseHandle(file);
    if (!flushed || !closed)
        return SQLITE_IOERR_FSYNC;
    if (!MoveFileExA(temporary, destination, MOVEFILE_WRITE_THROUGH))
        return SQLITE_IOERR;
    (void)directory;
#else
    int file = open(temporary, O_RDONLY);
    if (file < 0)
        return SQLITE_IOERR_FSYNC;
    int flushed = fsync(file);
    int closed = close(file);
    if (flushed || closed)
        return SQLITE_IOERR_FSYNC;
    if (rename(temporary, destination))
        return SQLITE_IOERR;
    int dir = open(directory, O_RDONLY | O_DIRECTORY);
    if (dir < 0)
        return SQLITE_IOERR_FSYNC;
    flushed = fsync(dir);
    closed = close(dir);
    if (flushed || closed)
        return SQLITE_IOERR_FSYNC;
#endif
    return SQLITE_OK;
}
