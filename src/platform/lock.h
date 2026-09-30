#ifndef SPICA_LOCK_H
#define SPICA_LOCK_H
#include <stddef.h>
#include <stdint.h>
/* 0 means lock acquisition failed; pass the nonzero token to release. */
uintptr_t spica_lock_directory(const char *lock_file);
void spica_unlock_directory(uintptr_t token);
/* Windows LocalAppData, UTF-8; returns 0 on other platforms/failure. */
int spica_local_app_data(char *buffer, size_t capacity);
#endif
