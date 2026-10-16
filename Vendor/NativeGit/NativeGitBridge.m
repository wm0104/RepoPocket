#import <Foundation/Foundation.h>
#include "NativeGitBridge.h"
char *rp_git_execute(const char *operation, const char *requestJSON) {
    return strdup("{\"ok\":false,\"error\":\"Native Git operations not implemented\"}");
}
void rp_git_free(char *value) { free(value); }
