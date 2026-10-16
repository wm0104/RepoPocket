#ifndef RPP_DEB_CODECS_H
#define RPP_DEB_CODECS_H
#include <stddef.h>
#include "../NativeGit/NativeGitBridge.h"
int rpp_decode(int format, const void *src, size_t length, void *dst, size_t capacity, size_t *written);
#endif
