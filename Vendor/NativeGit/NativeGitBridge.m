#import <Foundation/Foundation.h>
#include <git2.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include "NativeGitBridge.h"

// No Git subprocesses, hooks or credentials in persistent configuration.
@interface RPGitResources : NSObject
@property NSMutableArray *releases;
- (void)hold:(void *)pointer release:(void (*)(void *))release;
- (void)close;
@end
@implementation RPGitResources
- (instancetype)init { if ((self = [super init])) _releases = [NSMutableArray array]; return self; }
- (void)hold:(void *)pointer release:(void (*)(void *))release {
    if (pointer) [self.releases addObject:^{ release(pointer); }];
}
- (void)close { for (void (^release)(void) in self.releases.reverseObjectEnumerator) release(); [self.releases removeAllObjects]; }
@end
#define KEEP(p, fn) [c hold:(p) release:(void (*)(void *))(fn)]
static void RPRequire(BOOL valid, NSString *reason) {
    if (!valid) @throw [NSException exceptionWithName:@"RPGit" reason:reason userInfo:nil];
}
static void RPCheck(int result, NSString *reason) { RPRequire(result >= 0, reason); }
static NSString *RPString(NSDictionary *request, NSString *key) {
    id value = request[key];
    RPRequire([value isKindOfClass:NSString.class] && [value length] &&
              [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location == NSNotFound,
              [@"缺少或无效的参数：" stringByAppendingString:key]);
    return value;
}
static NSString *RPOID(const git_oid *oid) {
    char value[GIT_OID_HEXSZ + 1]; git_oid_tostr(value, sizeof(value), oid);
    return @(value);
}
static NSString *RPReal(NSString *path) {
    char value[PATH_MAX];
    RPRequire(realpath(path.fileSystemRepresentation, value) != NULL, @"目录不可访问，请重新授权原文件夹。");
    return [NSString stringWithUTF8String:value];
}
static NSString *RPPath(NSString *root, NSString *relative, BOOL allowMissing) {
    RPRequire(!relative.isAbsolutePath && ![relative containsString:@"\\"] && relative.length < 4096,
              @"文件路径无效。");
    NSArray *parts = [relative componentsSeparatedByString:@"/"];
    NSString *path = root;
    for (NSString *part in parts) {
        RPRequire(part.length && ![part isEqual:@"."] && ![part isEqual:@".."] &&
                  ![part.lowercaseString isEqual:@".git"], @"不能访问 Git 元数据或项目外的文件。");
        path = [path stringByAppendingPathComponent:part];
        struct stat s;
        if (lstat(path.fileSystemRepresentation, &s) == 0) {
            RPRequire(!S_ISLNK(s.st_mode), @"符号链接不可编辑或提交，请先在原工具处理。");
        } else { RPRequire(allowMissing && errno == ENOENT, @"文件不可访问。"); }
    }
    return path;
}
static NSString *RPFingerprint(NSString *root, NSString *relative) {
    NSString *path = RPPath(root, relative, YES);
    struct stat s;
    if (lstat(path.fileSystemRepresentation, &s) != 0) {
        RPRequire(errno == ENOENT, @"文件状态读取失败。"); return @"missing";
    }
    RPRequire(S_ISREG(s.st_mode) && s.st_size <= 128 * 1024 * 1024, @"不是普通文件或超过 128 MiB 提交限制。");
    git_oid oid;
    RPCheck(git_odb_hashfile(&oid, path.fileSystemRepresentation, GIT_OBJECT_BLOB), @"计算文件指纹失败。");
    return [NSString stringWithFormat:@"%@: %o", RPOID(&oid), s.st_mode & 0111];
}
static git_repository *RPOpen(NSDictionary *q, RPGitResources *c) {
    NSString *metadata = RPReal(RPString(q, @"repository"));
    NSString *workdir = RPReal(RPString(q, @"workdir"));
    RPRequire(![[NSFileManager defaultManager] fileExistsAtPath:[metadata stringByAppendingPathComponent:@"repopocket-transaction.json"]],
              @"上一次 Git 写入未完成。文件与提交已保留，请先检查仓库状态。");
    git_repository *repo = NULL;
    RPCheck(git_repository_open_ext(&repo, metadata.fileSystemRepresentation,
            GIT_REPOSITORY_OPEN_NO_SEARCH | GIT_REPOSITORY_OPEN_NO_DOTGIT, NULL), @"不是可打开的 Git 项目。");
    KEEP(repo, git_repository_free);
    RPRequire(!git_repository_is_worktree(repo), @"第一版暂不接管 Git worktree。");
    if ([q[@"privateGit"] boolValue]) {
        RPCheck(git_repository_set_workdir(repo, workdir.fileSystemRepresentation, 0), @"无法关联原工作目录。");
    } else {
        NSString *dotGit = [workdir stringByAppendingPathComponent:@".git"];
        struct stat s;
        RPRequire(lstat(dotGit.fileSystemRepresentation, &s) == 0 && S_ISDIR(s.st_mode) &&
                  [RPReal(dotGit) isEqual:metadata] && git_repository_workdir(repo) &&
                  [RPReal(@(git_repository_workdir(repo))) isEqual:workdir], @"Git 目录与原文件夹不匹配。");
    }
    RPRequire(![[NSFileManager defaultManager] fileExistsAtPath:[workdir stringByAppendingPathComponent:@".gitmodules"]],
              @"第一版暂不接管子模块。");
    return repo;
}
static git_reference *RPHead(git_repository *repo, RPGitResources *c) {
    git_reference *head = NULL;
    RPCheck(git_repository_head(&head, repo), @"需要具有提交历史的当前分支，暂不接管空仓库。"); KEEP(head, git_reference_free);
    RPRequire(git_reference_is_branch(head) && git_repository_head_detached(repo) == 0, @"请先在原工具切换到正常分支。");
    return head;
}
static git_tree *RPTree(git_repository *repo, git_reference *head, RPGitResources *c) {
    git_commit *commit = NULL; git_tree *tree = NULL;
    RPCheck(git_commit_lookup(&commit, repo, git_reference_target(head)), @"读取当前提交失败。"); KEEP(commit, git_commit_free);
    RPCheck(git_commit_tree(&tree, commit), @"读取当前文件树失败。"); KEEP(tree, git_tree_free);
    return tree;
}
static NSDictionary *RPStatus(git_repository *repo, RPGitResources *c) {
    git_reference *head = RPHead(repo, c);
    git_status_options options = GIT_STATUS_OPTIONS_INIT;
    options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    git_status_list *list = NULL;
    RPCheck(git_status_list_new(&list, repo, &options), @"无法检查变化，请确认原目录权限。"); KEEP(list, git_status_list_free);
    NSMutableArray *files = [NSMutableArray array], *staged = [NSMutableArray array];
    RPRequire(git_status_list_entrycount(list) <= 10000, @"变化超过 10000 项，请使用桌面 Git 处理。");
    for (size_t i = 0; i < git_status_list_entrycount(list); i++) {
        const git_status_entry *entry = git_status_byindex(list, i);
        const git_diff_delta *delta = entry->index_to_workdir ?: entry->head_to_index;
        const char *raw = delta->new_file.path ?: delta->old_file.path;
        NSString *path = [NSString stringWithUTF8String:raw];
        RPRequire(path != nil, @"文件名不是有效 UTF-8，请使用原工具处理。");
        unsigned indexFlags = GIT_STATUS_INDEX_NEW | GIT_STATUS_INDEX_MODIFIED | GIT_STATUS_INDEX_DELETED |
                              GIT_STATUS_INDEX_RENAMED | GIT_STATUS_INDEX_TYPECHANGE | GIT_STATUS_CONFLICTED;
        if (entry->status & indexFlags) [staged addObject:path];
        NSString *kind = (entry->status & (GIT_STATUS_WT_DELETED | GIT_STATUS_INDEX_DELETED)) ? @"deleted" :
                         ((entry->status & (GIT_STATUS_WT_NEW | GIT_STATUS_INDEX_NEW)) ? @"added" : @"modified");
        NSString *fingerprint = @"", *blocked = @"";
        @try { fingerprint = RPFingerprint(@(git_repository_workdir(repo)), path); }
        @catch (NSException *error) { blocked = error.reason ?: @"文件不可提交"; }
        [files addObject:@{@"path":path, @"kind":kind, @"fingerprint":fingerprint, @"blocked":blocked}];
    }
    return @{@"head":RPOID(git_reference_target(head)), @"branch":@(git_reference_shorthand(head)),
             @"files":files, @"staged":staged, @"repoState":@(git_repository_state(repo))};
}
static void RPWritable(git_repository *repo, NSDictionary *status) {
    RPRequire(git_repository_state(repo) == GIT_REPOSITORY_STATE_NONE && [status[@"staged"] count] == 0,
              @"仓库已有暂存、冲突或合并操作，请先在原工具处理；不会撤销原暂存。");
    git_index *index = NULL;
    RPCheck(git_repository_index(&index, repo), @"无法读取暂存区。");
    BOOL submodule = NO;
    for (size_t i=0; i<git_index_entrycount(index); i++) if (git_index_get_byindex(index, i)->mode == GIT_FILEMODE_COMMIT) submodule = YES;
    git_index_free(index);
    RPRequire(!submodule, @"第一版暂不接管子模块。");
}
static NSDictionary *RPDiff(git_repository *repo, NSDictionary *q, RPGitResources *c) {
    NSString *path = RPString(q, @"path"); RPPath(@(git_repository_workdir(repo)), path, YES);
    git_reference *head = RPHead(repo, c);
    RPRequire([RPOID(git_reference_target(head)) isEqual:RPString(q, @"expectedHead")], @"分支已变化，请重新检查。");
    git_diff_options options = GIT_DIFF_OPTIONS_INIT;
    options.flags = GIT_DIFF_INCLUDE_UNTRACKED | GIT_DIFF_RECURSE_UNTRACKED_DIRS |
                    GIT_DIFF_SHOW_UNTRACKED_CONTENT | GIT_DIFF_DISABLE_PATHSPEC_MATCH;
    options.max_size = 256 * 1024;
    char *onePath = (char *)path.UTF8String; options.pathspec.strings = &onePath; options.pathspec.count = 1;
    git_diff *diff = NULL;
    RPCheck(git_diff_tree_to_workdir_with_index(&diff, repo, RPTree(repo, head, c), &options), @"读取差异失败。"); KEEP(diff, git_diff_free);
    NSMutableString *text = [NSMutableString string]; BOOL binary = NO, truncated = NO;
    for (size_t i=0; i<git_diff_num_deltas(diff); i++) {
        git_patch *patch = NULL;
        RPCheck(git_patch_from_diff(&patch, diff, i), @"生成差异失败。"); KEEP(patch, git_patch_free);
        if (!patch || (git_patch_get_delta(patch)->flags & GIT_DIFF_FLAG_BINARY)) { binary = YES; continue; }
        git_buf buffer = GIT_BUF_INIT;
        int rc = git_patch_to_buf(&buffer, patch);
        if (rc < 0 || buffer.size > 256 * 1024) { git_buf_dispose(&buffer); truncated = YES; break; }
        NSString *piece = [[NSString alloc] initWithBytes:buffer.ptr length:buffer.size encoding:NSUTF8StringEncoding];
        git_buf_dispose(&buffer);
        if (!piece) { binary = YES; continue; }
        if ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [piece lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 256 * 1024) { truncated = YES; break; }
        [text appendString:piece];
    }
    return @{@"text":text, @"binary":@(binary), @"truncated":@(truncated)};
}
static void RPVerifyFiles(git_repository *repo, NSArray *selected, NSDictionary *status) {
    RPRequire([selected isKindOfClass:NSArray.class] && selected.count && selected.count <= 1000, @"请选择 1 至 1000 个文件。");
    NSMutableDictionary *current = [NSMutableDictionary dictionary];
    for (NSDictionary *row in status[@"files"]) current[row[@"path"]] = row;
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *row in selected) {
        RPRequire([row isKindOfClass:NSDictionary.class], @"提交参数无效。");
        NSString *path = RPString(row, @"path"), *fingerprint = RPString(row, @"fingerprint");
        RPRequire(![seen containsObject:path] && current[path] && ![current[path][@"blocked"] length], @"选中文件已变化或不受支持，请重新检查。");
        [seen addObject:path];
        const char *filter = NULL;
        RPCheck(git_attr_get(&filter, repo, GIT_ATTR_CHECK_FILE_THEN_INDEX, path.UTF8String, "filter"), @"读取文件属性失败。");
        RPRequire(!GIT_ATTR_HAS_VALUE(filter) || strcmp(filter, "lfs") != 0, @"第一版暂不支持 Git LFS 文件提交。");
        RPRequire([RPFingerprint(@(git_repository_workdir(repo)), path) isEqual:fingerprint], @"文件在预览后发生变化，请重新检查；修改已保留。");
    }
}
static NSDictionary *RPCommit(git_repository *repo, NSDictionary *q, RPGitResources *c) {
    NSString *metadata = @(git_repository_path(repo));
    NSString *lock = [metadata stringByAppendingPathComponent:@"index.lock"];
    int fd = open(lock.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
    RPRequire(fd >= 0, @"Git 暂存区被其他操作锁定，请稍后检查；原锁文件未更改。");
    close(fd);
    NSString *temporary = [metadata stringByAppendingPathComponent:[@"repopocket-index-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *journal = [metadata stringByAppendingPathComponent:@"repopocket-transaction.json"];
    BOOL began = NO;
    @try {
        NSDictionary *status = RPStatus(repo, c); RPWritable(repo, status);
        RPRequire([status[@"head"] isEqual:RPString(q, @"expectedHead")], @"分支已变化，请重新检查。");
        NSArray *selected = q[@"files"]; RPVerifyFiles(repo, selected, status);
        git_reference *head = RPHead(repo, c); git_tree *before = RPTree(repo, head, c);
        git_index *index = NULL;
        RPCheck(git_repository_index(&index, repo), @"读取暂存区失败。"); KEEP(index, git_index_free);
        RPCheck(git_index_read_tree(index, before), @"准备本次提交失败。");
        for (NSDictionary *row in selected) {
            NSString *path = row[@"path"];
            if ([row[@"fingerprint"] isEqual:@"missing"]) RPCheck(git_index_remove_bypath(index, path.UTF8String), @"准备删除记录失败。");
            else RPCheck(git_index_add_bypath(index, path.UTF8String), @"读取选中文件失败。");
        }
        git_oid treeID, commitID;
        RPCheck(git_index_write_tree(&treeID, index), @"创建本地文件树失败。");
        RPRequire(!git_oid_equal(&treeID, git_tree_id(before)), @"没有可提交的内容变化。");
        git_tree *tree = NULL; git_commit *parent = NULL; git_signature *author = NULL;
        RPCheck(git_tree_lookup(&tree, repo, &treeID), @"读取新文件树失败。"); KEEP(tree, git_tree_free);
        RPCheck(git_commit_lookup(&parent, repo, git_reference_target(head)), @"读取父提交失败。"); KEEP(parent, git_commit_free);
        RPCheck(git_signature_now(&author, RPString(q,@"authorName").UTF8String, RPString(q,@"authorEmail").UTF8String), @"作者姓名或邮箱无效。"); KEEP(author, git_signature_free);
        const git_commit *parents[] = {parent};
        RPCheck(git_commit_create(&commitID, repo, NULL, author, author, "UTF-8", RPString(q,@"message").UTF8String, tree, 1, parents), @"创建本地提交失败。");
        git_index *prepared = NULL;
        RPCheck(git_index_open(&prepared, temporary.fileSystemRepresentation), @"准备事务暂存区失败。"); KEEP(prepared, git_index_free);
        for (size_t i=0; i<git_index_entrycount(index); i++) RPCheck(git_index_add(prepared, git_index_get_byindex(index,i)), @"准备暂存区失败。");
        RPCheck(git_index_write(prepared), @"保存事务暂存区失败。");
        RPVerifyFiles(repo, selected, status);
        NSDictionary *intent = @{@"oldHead":status[@"head"], @"newHead":RPOID(&commitID), @"preparedIndex":temporary.lastPathComponent};
        NSData *record = [NSJSONSerialization dataWithJSONObject:intent options:0 error:nil];
        RPRequire([record writeToFile:journal options:NSDataWritingAtomic error:nil], @"无法保存提交恢复信息。"); began = YES;
        git_reference *updated = NULL;
        int rc = git_reference_create_matching(&updated, repo, git_reference_name(head), &commitID, 1,
                                              git_reference_target(head), "RepoPocket selected commit");
        KEEP(updated, git_reference_free);
        if (rc < 0) {
            unlink(journal.fileSystemRepresentation); began = NO;
            RPRequire(NO, @"分支在提交时被其他工具改动，请重新检查；工作文件已保留。");
        }
        RPRequire(rename(temporary.fileSystemRepresentation, [[metadata stringByAppendingPathComponent:@"index"] fileSystemRepresentation]) == 0,
                  @"提交已保存，但暂存区更新中断；恢复信息已保留，请先检查仓库。");
        unlink(journal.fileSystemRepresentation); began = NO;
        return @{@"commit":RPOID(&commitID)};
    } @finally {
        if (!began) unlink(temporary.fileSystemRepresentation);
        unlink(lock.fileSystemRepresentation);
    }
}

static BOOL RPAllowedRemote(NSString *raw) {
    NSURLComponents *url = [NSURLComponents componentsWithString:raw];
#ifdef RP_GIT_TESTING
    if ([url.scheme isEqual:@"file"] && !url.host.length) return YES;
#endif
    if (![url.scheme isEqual:@"https"] || ![url.host.lowercaseString isEqual:@"github.com"] ||
        url.user || url.password || url.query || url.fragment || (url.port && url.port.intValue != 443)) return NO;
    NSArray *parts = [url.path componentsSeparatedByString:@"/"];
    if (parts.count != 3) return NO;
    for (NSString *part in [parts subarrayWithRange:NSMakeRange(1,2)]) {
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] || [part containsString:@"\\"] ||
            [part rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return NO;
    }
    return YES;
}
static int RPCredentials(git_credential **out, const char *url, const char *username, unsigned types, void *payload) {
    NSMutableDictionary *q = (__bridge NSMutableDictionary *)payload;
    if (!url || !RPAllowedRemote(@(url)) || ![@(url) isEqual:q[@"credentialRemote"]] ||
        ![q[@"token"] isKindOfClass:NSString.class] || ![q[@"token"] length] ||
        !(types & GIT_CREDENTIAL_USERPASS_PLAINTEXT) || [q[@"credentialUsed"] boolValue]) return GIT_EAUTH;
    q[@"credentialUsed"] = @YES;
    return git_credential_userpass_plaintext_new(out, "x-access-token", [q[@"token"] UTF8String]);
}
static int RPCertificate(git_cert *certificate, int valid, const char *host, void *payload) {
    return valid && host && [@(host).lowercaseString isEqual:@"github.com"] ? 0 : GIT_ECERTIFICATE;
}
static int RPReady(git_remote *remote, int direction, void *payload) {
    NSDictionary *q = (__bridge NSDictionary *)payload;
    const char *raw = direction == GIT_DIRECTION_PUSH ? git_remote_pushurl(remote) : NULL;
    if (!raw) raw = git_remote_url(remote);
    return raw && RPAllowedRemote(@(raw)) && [@(raw) isEqual:q[@"credentialRemote"]] ? 0 : GIT_EINVALIDSPEC;
}
static int RPPushResult(const char *ref, const char *error, void *payload) {
    if (error) { ((__bridge NSMutableDictionary *)payload)[@"pushRejected"] = @YES; return GIT_EUSER; }
    return 0;
}
static git_remote_callbacks RPCallbacks(NSMutableDictionary *q) {
    git_remote_callbacks callbacks = GIT_REMOTE_CALLBACKS_INIT;
    callbacks.credentials = RPCredentials; callbacks.certificate_check = RPCertificate;
    callbacks.remote_ready = RPReady; callbacks.push_update_reference = RPPushResult;
    callbacks.payload = (__bridge void *)q;
    return callbacks;
}
static void RPBranch(NSString *branch) {
    int valid = 0; RPCheck(git_branch_name_is_valid(&valid, branch.UTF8String), @"分支名称无效。");
    RPRequire(valid, @"分支名称无效。");
}
static git_remote *RPRemote(git_repository *repo, NSMutableDictionary *q, RPGitResources *c) {
    git_remote *remote = NULL;
    RPCheck(git_remote_lookup(&remote, repo, "origin"), @"没有 origin 远端，请先确认关联仓库。"); KEEP(remote, git_remote_free);
    const char *raw = git_remote_url(remote), *push = git_remote_pushurl(remote);
    RPRequire(raw && RPAllowedRemote(@(raw)) && (!push || (RPAllowedRemote(@(push)) && strcmp(raw,push)==0)),
              @"远端不是受支持的 GitHub HTTPS 地址，或推送地址与 origin 不同，已停止同步。");
    if (q[@"expectedRemote"]) RPRequire([q[@"expectedRemote"] isEqual:@(raw)], @"远端地址已变化，请重新确认目标仓库。");
    // A repository must not be able to turn off system TLS verification.
    git_config *config = NULL; git_config_iterator *iterator = NULL;
    RPCheck(git_repository_config(&config, repo), @"无法读取 Git 配置。"); KEEP(config, git_config_free);
    RPCheck(git_config_iterator_new(&iterator, config), @"无法核对 Git 安全配置。"); KEEP(iterator, git_config_iterator_free);
    git_config_entry *entry;
    while (git_config_next(&entry, iterator) == 0) {
        NSString *key = @(entry->name);
        if ([key hasSuffix:@".sslverify"]) {
            int enabled = 0;
            RPCheck(git_config_parse_bool(&enabled, entry->value), @"TLS 配置无效。");
            RPRequire(enabled, @"仓库关闭了 TLS 验证，已停止同步。请先在原工具修正配置。");
        }
    }
    q[@"credentialRemote"] = @(raw); q[@"credentialUsed"] = @NO;
    return remote;
}
static void RPFetch(git_repository *repo, NSMutableDictionary *q, RPGitResources *c) {
    git_remote *remote = RPRemote(repo, q, c);
    git_fetch_options options = GIT_FETCH_OPTIONS_INIT;
    options.callbacks = RPCallbacks(q); options.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
    options.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE;
    RPCheck(git_remote_fetch(remote, NULL, &options, "RepoPocket fetch"), @"获取远端失败：请检查网络、账号权限或取消状态；本地提交已保留。");
}
static NSDictionary *RPHistory(git_repository *repo, RPGitResources *c) {
    git_reference *head = RPHead(repo,c), *upstream = NULL;
    size_t ahead = 0, behind = 0; BOOL tracked = git_branch_upstream(&upstream, head) == 0;
    KEEP(upstream, git_reference_free);
    if (tracked) RPCheck(git_graph_ahead_behind(&ahead,&behind,repo,git_reference_target(head),git_reference_target(upstream)), @"比较本地与远端历史失败。");
    git_revwalk *walk = NULL; RPCheck(git_revwalk_new(&walk,repo), @"读取本地历史失败。"); KEEP(walk, git_revwalk_free);
    git_revwalk_sorting(walk,GIT_SORT_TOPOLOGICAL | GIT_SORT_TIME); RPCheck(git_revwalk_push(walk,git_reference_target(head)), @"读取历史失败。");
    NSMutableArray *commits = [NSMutableArray array]; git_oid oid;
    while (commits.count < 30 && git_revwalk_next(&oid,walk)==0) {
        git_commit *commit = NULL; RPCheck(git_commit_lookup(&commit,repo,&oid), @"读取提交失败。"); KEEP(commit, git_commit_free);
        [commits addObject:@{@"sha":RPOID(&oid), @"message":@(git_commit_summary(commit) ?: ""),
                             @"author":@(git_commit_author(commit)->name ?: ""), @"time":@(git_commit_time(commit))}];
    }
    NSString *remoteURL = @""; git_remote *remote = NULL;
    if (git_remote_lookup(&remote,repo,"origin")==0) {
        KEEP(remote,git_remote_free);
        if (git_remote_url(remote) && RPAllowedRemote(@(git_remote_url(remote)))) remoteURL = @(git_remote_url(remote));
    }
    return @{@"commits":commits, @"ahead":@(ahead), @"behind":@(behind), @"tracking":@(tracked), @"remote":remoteURL};
}
static git_transaction *RPLockHead(git_repository *repo, git_reference *head, RPGitResources *c) {
    git_transaction *tx = NULL; RPCheck(git_transaction_new(&tx,repo), @"创建 Git 事务失败。"); KEEP(tx,git_transaction_free);
    RPCheck(git_transaction_lock_ref(tx,"HEAD"), @"当前分支被其他工具锁定。");
    RPCheck(git_transaction_lock_ref(tx,git_reference_name(head)), @"当前分支被其他工具锁定。");
    return tx;
}
static NSDictionary *RPPull(git_repository *repo, NSMutableDictionary *q, RPGitResources *c) {
    NSDictionary *status = RPStatus(repo,c); RPWritable(repo,status);
    RPRequire([status[@"files"] count]==0, @"请先提交本地修改，再拉取；不会自动覆盖、暂存或清理文件。");
    RPRequire([status[@"head"] isEqual:RPString(q,@"expectedHead")], @"分支已变化，请重新检查。");
    RPFetch(repo,q,c);
    git_reference *head = RPHead(repo,c), *upstream = NULL;
    RPCheck(git_branch_upstream(&upstream,head), @"当前分支尚未关联远端分支。"); KEEP(upstream,git_reference_free);
    const git_oid *target = git_reference_target(upstream), *before = git_reference_target(head);
    if (git_oid_equal(target,before)) return @{@"head":RPOID(before)};
    RPRequire(git_graph_descendant_of(repo,target,before)==1, @"两端已有不同提交，停止拉取；请先在桌面 Git 处理分叉。");
    git_transaction *tx = RPLockHead(repo,head,c);
    NSDictionary *fresh = RPStatus(repo,c); RPWritable(repo,fresh);
    RPRequire([fresh[@"head"] isEqual:status[@"head"]] && [fresh[@"files"] count]==0, @"拉取前发现本地新变化，已停止。");
    git_object *commit = NULL; RPCheck(git_object_lookup(&commit,repo,target,GIT_OBJECT_COMMIT), @"读取远端提交失败。"); KEEP(commit,git_object_free);
    git_checkout_options options = GIT_CHECKOUT_OPTIONS_INIT;
    options.checkout_strategy = GIT_CHECKOUT_SAFE | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED | GIT_CHECKOUT_DRY_RUN;
    RPCheck(git_checkout_tree(repo,commit,&options), @"远端文件会覆盖本地内容（含忽略文件），已停止拉取。");
    NSString *journal = [@(git_repository_path(repo)) stringByAppendingPathComponent:@"repopocket-transaction.json"];
    NSData *intent = [NSJSONSerialization dataWithJSONObject:@{@"operation":@"pull",@"oldHead":RPOID(before),@"newHead":RPOID(target)} options:0 error:nil];
    RPRequire([intent writeToFile:journal options:NSDataWritingAtomic error:nil], @"无法保存拉取恢复信息。");
    options.checkout_strategy &= ~GIT_CHECKOUT_DRY_RUN;
    RPCheck(git_checkout_tree(repo,commit,&options), @"拉取未完整完成，文件和恢复信息已保留，请先检查仓库。");
    git_signature *signature = NULL;
    RPCheck(git_signature_now(&signature,"RepoPocket","local@repopocket.invalid"), @"无法创建操作记录。"); KEEP(signature,git_signature_free);
    RPCheck(git_transaction_set_target(tx,git_reference_name(head),target,signature,"RepoPocket fast-forward pull"), @"保存分支更新失败，恢复信息已保留。");
    RPCheck(git_transaction_commit(tx), @"分支更新未完成，恢复信息已保留。");
    unlink(journal.fileSystemRepresentation);
    return @{@"head":RPOID(target)};
}
static NSDictionary *RPPush(git_repository *repo, NSMutableDictionary *q, RPGitResources *c) {
    NSDictionary *status = RPStatus(repo,c); RPWritable(repo,status);
    RPRequire([status[@"head"] isEqual:RPString(q,@"expectedHead")], @"分支已变化，请重新检查。");
    git_reference *head = RPHead(repo,c); git_transaction *lock = RPLockHead(repo,head,c); (void)lock;
    git_remote *remote = RPRemote(repo,q,c);
    NSString *spec = [NSString stringWithFormat:@"%@:%@", @(git_reference_name(head)), @(git_reference_name(head))];
    char *raw = (char *)spec.UTF8String; git_strarray refs = {&raw,1};
    git_push_options options = GIT_PUSH_OPTIONS_INIT;
    options.callbacks = RPCallbacks(q); options.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
    q[@"pushRejected"] = @NO;
    RPCheck(git_remote_push(remote,&refs,&options), @"推送被拒绝或网络中断：请检查权限及远端是否领先；不会强制推送，本地提交已保留。");
    RPRequire(![q[@"pushRejected"] boolValue], @"远端拒绝了推送，本地提交已保留。");
    return @{@"head":status[@"head"]};
}
static NSDictionary *RPCreate(NSString *op, NSMutableDictionary *q, RPGitResources *c) {
    NSString *remoteURL = RPString(q,@"remote"), *branch = RPString(q,@"branch");
    RPRequire(RPAllowedRemote(remoteURL), @"仅支持 GitHub HTTPS 仓库地址。"); RPBranch(branch);
    q[@"credentialRemote"] = remoteURL; q[@"credentialUsed"] = @NO;
    git_repository *repo = NULL;
    if ([op isEqual:@"clone"]) {
        NSString *requested = RPString(q,@"destination");
        NSString *parent = RPReal(requested.stringByDeletingLastPathComponent);
        NSString *destination = [parent stringByAppendingPathComponent:requested.lastPathComponent];
        struct stat existing;
        RPRequire(requested.isAbsolutePath && ![requested.lastPathComponent.lowercaseString isEqual:@".git"] &&
                  lstat(destination.fileSystemRepresentation,&existing) != 0 && errno == ENOENT,
                  @"克隆目标已存在或不安全，请选择新的子文件夹。");
        git_clone_options options = GIT_CLONE_OPTIONS_INIT;
        options.checkout_branch = branch.UTF8String;
        options.fetch_opts.callbacks = RPCallbacks(q); options.fetch_opts.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
        int rc = git_clone(&repo,remoteURL.UTF8String,destination.fileSystemRepresentation,&options); KEEP(repo,git_repository_free);
        RPCheck(rc,@"克隆未完成，请检查网络及权限；已有文件未删除，部分下载可能保留在目标文件夹。");
        return RPStatus(repo,c);
    }
    NSString *metadata = RPString(q,@"repository"), *workdir = RPReal(RPString(q,@"workdir"));
    RPReal(metadata.stringByDeletingLastPathComponent);
    RPRequire(![[NSFileManager defaultManager] fileExistsAtPath:metadata] &&
              ![[NSFileManager defaultManager] fileExistsAtPath:[workdir stringByAppendingPathComponent:@".git"]], @"目录已有关联或 Git 数据，请先检查原项目。");
    RPCheck(git_repository_init(&repo,metadata.fileSystemRepresentation,1), @"无法创建私有 Git 数据。"); KEEP(repo,git_repository_free);
    RPCheck(git_repository_set_workdir(repo,workdir.fileSystemRepresentation,0), @"无法打开原文件夹。");
    git_config *config = NULL; RPCheck(git_repository_config(&config,repo), @"读取私有配置失败。"); KEEP(config,git_config_free);
    RPCheck(git_config_set_bool(config,"core.bare",0), @"无法保存私有 Git 配置。");
    git_remote *remote = NULL;
    RPCheck(git_remote_create(&remote,repo,"origin",remoteURL.UTF8String), @"无法记录远端地址。"); KEEP(remote,git_remote_free);
    RPFetch(repo,q,c);
    git_reference *fetched = NULL;
    NSString *remoteRef = [@"refs/remotes/origin/" stringByAppendingString:branch];
    RPCheck(git_reference_lookup(&fetched,repo,remoteRef.UTF8String), @"所选远端分支不存在。"); KEEP(fetched,git_reference_free);
    git_oid baseline;
    RPCheck(git_oid_fromstr(&baseline,RPString(q,@"selectedCommit").UTF8String), @"比较基准提交无效。");
    RPRequire(git_oid_equal(&baseline,git_reference_target(fetched)) || git_graph_descendant_of(repo,git_reference_target(fetched),&baseline)==1,
              @"所选基准不在该分支历史中，请重新选择。");
    git_commit *commit = NULL; git_tree *tree = NULL; git_index *index = NULL; git_reference *local = NULL;
    RPCheck(git_commit_lookup(&commit,repo,&baseline), @"读取所选基准失败。"); KEEP(commit,git_commit_free);
    RPCheck(git_commit_tree(&tree,commit), @"读取基准文件树失败。"); KEEP(tree,git_tree_free);
    RPCheck(git_repository_index(&index,repo), @"创建私有暂存区失败。"); KEEP(index,git_index_free);
    RPCheck(git_index_read_tree(index,tree), @"读取基准暂存区失败。"); RPCheck(git_index_write(index), @"保存基准失败。");
    RPCheck(git_branch_create(&local,repo,branch.UTF8String,commit,0), @"创建本地当前分支失败。"); KEEP(local,git_reference_free);
    NSString *localRef = [@"refs/heads/" stringByAppendingString:branch];
    RPCheck(git_repository_set_head(repo,localRef.UTF8String), @"设置当前分支失败。");
    RPCheck(git_branch_set_upstream(local,[@"origin/" stringByAppendingString:branch].UTF8String), @"关联远端分支失败。");
    // No checkout: the user's pre-import edits remain in exactly the original folder.
    return RPStatus(repo,c);
}

char *rp_git_execute(const char *operation, const char *requestJSON) {
    @autoreleasepool {
        static dispatch_once_t initialized;
        dispatch_once(&initialized, ^{ git_libgit2_init(); });
        RPGitResources *c = [RPGitResources new]; NSDictionary *answer;
        @try {
            RPRequire(operation && requestJSON && strlen(requestJSON) <= 2 * 1024 * 1024, @"Git 请求无效。");
            NSData *bytes = [NSData dataWithBytes:requestJSON length:strlen(requestJSON)];
            NSMutableDictionary *q = [NSJSONSerialization JSONObjectWithData:bytes options:NSJSONReadingMutableContainers error:nil];
            RPRequire([q isKindOfClass:NSDictionary.class], @"Git 请求无效。");
            NSString *op = @(operation); NSDictionary *result = nil;
            if ([op isEqual:@"clone"] || [op isEqual:@"associate"]) result = RPCreate(op,q,c);
            else {
                git_repository *repo = RPOpen(q, c);
                if ([op isEqual:@"status"] || [op isEqual:@"inspect"]) result = RPStatus(repo, c);
                else if ([op isEqual:@"diff"]) result = RPDiff(repo, q, c);
                else if ([op isEqual:@"commit"]) result = RPCommit(repo, q, c);
                else if ([op isEqual:@"history"]) result = RPHistory(repo,c);
                else if ([op isEqual:@"fetch"]) { RPFetch(repo,q,c); result = RPHistory(repo,c); }
                else if ([op isEqual:@"pull"]) result = RPPull(repo,q,c);
                else if ([op isEqual:@"push"]) result = RPPush(repo,q,c);
                else RPRequire(NO, @"尚不支持此 Git 操作。");
            }
            answer = @{@"ok":@YES, @"result":result ?: @{}};
        } @catch (NSException *error) {
            // Never copy libgit2 transport/config diagnostics (which may contain URLs or credentials).
            answer = @{@"ok":@NO, @"error":[error.name isEqual:@"RPGit"] ? error.reason : @"Git 操作失败，文件已保留。"};
        } @finally { [c close]; }
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:answer options:0 error:nil];
        NSString *json = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
        return strdup(json.UTF8String ?: "{\"ok\":false,\"error\":\"Git response failed\"}");
    }
}
void rp_git_free(char *value) { free(value); }
