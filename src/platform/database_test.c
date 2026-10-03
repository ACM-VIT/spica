#include <stdlib.h>
#include <sys/stat.h>
#include "database.c"

static int value(sqlite3 *database) {
    sqlite3_stmt *statement = NULL;
    int result = -1;
    if (sqlite3_prepare_v2(database, "SELECT value FROM history", -1, &statement, NULL) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW)
        result = sqlite3_column_int(statement, 0);
    sqlite3_finalize(statement);
    return result;
}

int main(int argc, char **argv) {
    if (argc != 3 || chdir(argv[1]))
        return 1;
    int wal = !strcmp(argv[2], "wal");
    sqlite3 *database = NULL;
    if (sqlite3_open("legacy.sqlite", &database) != SQLITE_OK)
        return 2;
    int rc = sqlite3_exec(database, "CREATE TABLE history(value); INSERT INTO history VALUES(42);"
                          "PRAGMA user_version=6", NULL, NULL, NULL);
    if (rc == SQLITE_OK && wal)
        rc = sqlite3_exec(database, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);
    sqlite3_close(database);
    if (rc != SQLITE_OK)
        return 3;
    if (!wal && chmod("legacy.sqlite", 0444))
        return 4;
    if (wal) {
        /* Closing the last connection removes sidecars but leaves WAL mode in the header. */
        if (access("legacy.sqlite-wal", F_OK) == 0 || access("legacy.sqlite-shm", F_OK) == 0)
            return 5;
    }
    rc = spica_database_cutover("history.sqlite", "legacy.sqlite", "staging.sqlite", ".");
    if (rc != SQLITE_OK) {
        fprintf(stderr, "cutover: %d\n", rc);
        return 6;
    }
    if (open_validated("history.sqlite", &database) != SQLITE_OK)
        return 7;
    int copied = value(database);
    sqlite3_close(database);
    if (copied != 42)
        return 8;
    if (open_validated("legacy.sqlite", &database) != SQLITE_OK)
        return 9;
    int original = value(database);
    sqlite3_close(database);
    if (original != 42)
        return 10;
    return spica_database_cutover("history.sqlite", "legacy.sqlite", "staging.sqlite", ".") != SQLITE_OK;
}
