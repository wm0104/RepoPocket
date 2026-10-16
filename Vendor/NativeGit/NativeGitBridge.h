#ifndef RP_NATIVE_GIT_BRIDGE_H
#define RP_NATIVE_GIT_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif
char *rp_git_execute(const char *operation, const char *requestJSON);
void rp_git_free(char *value);
void rp_git_cancel(const char *requestID);
#ifdef __cplusplus
}
#endif
#endif
