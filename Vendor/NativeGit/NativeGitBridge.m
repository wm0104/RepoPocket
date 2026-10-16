#import <Foundation/Foundation.h>
#include <git2.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
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

char *rp_git_execute(const char *operation, const char *requestJSON) {
    @autoreleasepool {
        static dispatch_once_t initialized;
        dispatch_once(&initialized, ^{ git_libgit2_init(); });
        RPGitResources *c = [RPGitResources new]; NSDictionary *answer;
        @try {
            RPRequire(operation && requestJSON && strlen(requestJSON) <= 2 * 1024 * 1024, @"Git 请求无效。");
            NSData *bytes = [NSData dataWithBytes:requestJSON length:strlen(requestJSON)];
            NSDictionary *q = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
            RPRequire([q isKindOfClass:NSDictionary.class], @"Git 请求无效。");
            NSString *op = @(operation); NSDictionary *result = nil;
            git_repository *repo = RPOpen(q, c);
            if ([op isEqual:@"status"] || [op isEqual:@"inspect"]) result = RPStatus(repo, c);
            else if ([op isEqual:@"diff"]) result = RPDiff(repo, q, c);
            else if ([op isEqual:@"commit"]) result = RPCommit(repo, q, c);
            else RPRequire(NO, @"尚不支持此 Git 操作。");
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
