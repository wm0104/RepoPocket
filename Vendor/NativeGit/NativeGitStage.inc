// Included by NativeGitBridge.m after RPLockHead / RPSerializeDiff. No subprocesses.
static NSString *RPStageIndexFingerprint(git_repository *repo) {
    return RPFingerprint(@(git_repository_path(repo)), @"index");
}
static git_index *RPStageIndex(git_repository *repo,RPGitResources *c) {
    git_index *index=NULL; RPCheck(git_repository_index(&index,repo),@"无法读取暂存区。"); KEEP(index,git_index_free);
    RPCheck(git_index_read(index,1),@"无法刷新暂存区。");
    RPRequire(!git_index_has_conflicts(index),@"暂存区有冲突，请先完成冲突解决。");
    RPRequire(git_index_entrycount(index)<=10000,@"暂存区超过 10000 项，请使用桌面 Git。");
    for(size_t i=0;i<git_index_entrycount(index);i++) {
        const git_index_entry *entry=git_index_get_byindex(index,i);
        RPRequire(entry->mode==GIT_FILEMODE_BLOB || entry->mode==GIT_FILEMODE_BLOB_EXECUTABLE,@"暂存区包含符号链接、子模块或不支持的类型，未修改任何内容。");
        RPRequire(!(entry->flags_extended & (GIT_INDEX_ENTRY_INTENT_TO_ADD | GIT_INDEX_ENTRY_SKIP_WORKTREE)) && !(entry->flags & GIT_INDEX_ENTRY_VALID),@"暂不接管 intent-to-add、skip-worktree 或 assume-unchanged 暂存项。");
    }
    return index;
}
static void RPStageGuard(git_repository *repo,NSDictionary *status) {
    RPRequire(![status[@"mergePending"] boolValue] && [status[@"repoState"] intValue]==GIT_REPOSITORY_STATE_NONE && git_repository_state(repo)==GIT_REPOSITORY_STATE_NONE,@"存在合并、冲突或中断操作，请先完成或安全恢复；不会改动现有暂存。");
}
static void RPStageFilter(git_repository *repo,NSString *path) {
    RPPath(@(git_repository_workdir(repo)),path,YES);
    for(int source=0;source<2;source++) {
        const char *filter=NULL;
        RPCheck(git_attr_get(&filter,repo,source ? GIT_ATTR_CHECK_INDEX_ONLY : GIT_ATTR_CHECK_FILE_THEN_INDEX,path.UTF8String,"filter"),@"无法核对文件属性。");
        RPRequire(!GIT_ATTR_HAS_VALUE(filter),@"暂不接管 LFS 或自定义 clean/smudge 过滤器文件。");
    }
}
static NSString *RPStageEntryFingerprint(const git_index_entry *entry) {
    return entry ? [NSString stringWithFormat:@"%@:%o",RPOID(&entry->id),entry->mode] : @"missing";
}
static NSDictionary *RPStageStatus(git_repository *repo,NSDictionary *q,RPGitResources *c) {
    NSString *pin=RPStageIndexFingerprint(repo);
    NSDictionary *status=RPStatus(repo,c); RPStageGuard(repo,status);
    git_index *index=RPStageIndex(repo,c);
    git_status_options options=GIT_STATUS_OPTIONS_INIT;
    options.flags=GIT_STATUS_OPT_INCLUDE_UNTRACKED|GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    git_status_list *list=NULL; RPCheck(git_status_list_new(&list,repo,&options),@"无法读取暂存状态。"); KEEP(list,git_status_list_free);
    NSMutableArray *staged=[NSMutableArray new],*unstaged=[NSMutableArray new];
    RPRequire(git_status_list_entrycount(list)<=10000,@"变化超过 10000 项。");
    for(size_t i=0;i<git_status_list_entrycount(list);i++) {
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"暂存检查已取消。");
        const git_status_entry *entry=git_status_byindex(list,i);
        for(int side=0;side<2;side++) {
            const git_diff_delta *delta=side ? entry->index_to_workdir : entry->head_to_index;
            if(!delta || delta->status==GIT_DELTA_UNMODIFIED) continue;
            NSString *path=[NSString stringWithUTF8String:delta->new_file.path ?: delta->old_file.path];
            RPRequire(path!=nil,@"文件名不是 UTF-8。");
            NSString *fingerprint=@"",*blocked=@"";
            @try {
                RPRequire((delta->old_file.mode==0 || delta->old_file.mode==GIT_FILEMODE_BLOB || delta->old_file.mode==GIT_FILEMODE_BLOB_EXECUTABLE) &&
                          (delta->new_file.mode==0 || delta->new_file.mode==GIT_FILEMODE_BLOB || delta->new_file.mode==GIT_FILEMODE_BLOB_EXECUTABLE),@"变化涉及符号链接、子模块或目录类型，未接管此路径。");
                RPStageFilter(repo,path);
                fingerprint=side ? RPFingerprint(@(git_repository_workdir(repo)),path) : RPStageEntryFingerprint(git_index_get_bypath(index,path.UTF8String,0));
            } @catch(NSException *error) { blocked=error.reason ?: @"文件不受支持"; }
            [(side ? unstaged : staged) addObject:@{@"path":path,@"fingerprint":fingerprint,@"blocked":blocked,@"kind":delta->status==GIT_DELTA_DELETED ? @"deleted" : (delta->status==GIT_DELTA_ADDED || delta->status==GIT_DELTA_UNTRACKED ? @"added" : @"modified")}];
        }
    }
    RPRequire([pin isEqual:RPStageIndexFingerprint(repo)],@"暂存区在检查期间变化，请刷新。");
    RPExpected(RPStatus(repo,c),@{@"expectedHead":status[@"head"],@"expectedRef":status[@"reference"]});
    return @{@"head":status[@"head"],@"reference":status[@"reference"],@"branch":status[@"branch"],@"indexFingerprint":pin,@"staged":staged,@"unstaged":unstaged};
}
static void RPStageExpected(git_repository *repo,NSDictionary *status,NSDictionary *q) {
    RPExpected(status,q);
    RPRequire([status[@"indexFingerprint"] isEqual:RPString(q,@"indexFingerprint")] && [RPStageIndexFingerprint(repo) isEqual:status[@"indexFingerprint"]],@"暂存区在预览后发生变化，请重新检查并确认。");
}
static NSArray *RPStageSelected(NSDictionary *status,NSDictionary *q,BOOL unstage) {
    NSArray *selected=q[@"files"]; RPRequire([selected isKindOfClass:NSArray.class] && selected.count && selected.count<=1000,@"请选择 1 至 1000 个文件。");
    NSMutableDictionary *rows=[NSMutableDictionary new]; for(NSDictionary *row in status[unstage ? @"staged" : @"unstaged"]) rows[row[@"path"]]=row;
    NSMutableSet *seen=[NSMutableSet new];
    for(NSDictionary *row in selected) {
        RPRequire([row isKindOfClass:NSDictionary.class],@"暂存参数无效。"); NSString *path=RPString(row,@"path");
        RPRequire(![seen containsObject:path] && rows[path] && ![rows[path][@"blocked"] length] && [rows[path][@"fingerprint"] isEqual:RPString(row,@"fingerprint")],@"选中文件在预览后变化或不受支持，请重新检查。"); [seen addObject:path];
    }
    return selected;
}
static NSString *RPStagePrepare(git_repository *repo,git_index *index,RPGitResources *c) {
    NSString *path=[@(git_repository_path(repo)) stringByAppendingPathComponent:[@"repopocket-index-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    git_index *prepared=NULL; RPCheck(git_index_open(&prepared,path.fileSystemRepresentation),@"无法准备独立暂存快照。"); KEEP(prepared,git_index_free);
    for(size_t i=0;i<git_index_entrycount(index);i++) RPCheck(git_index_add(prepared,git_index_get_byindex(index,i)),@"无法复制暂存项。");
    RPCheck(git_index_write(prepared),@"无法保存独立暂存快照。");
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW); RPRequire(fd>=0,@"无法核对已准备暂存快照。");
    int result=fsync(fd);close(fd); RPRequire(result==0,@"无法同步暂存快照。"); return path;
}
// Keep our descriptor open and remove only the exact inode we created, never another tool's lock.
static void RPStageUnlock(NSString *path,int fd) {
    struct stat owned,current;
    if(fstat(fd,&owned)==0 && lstat(path.fileSystemRepresentation,&current)==0 && owned.st_dev==current.st_dev && owned.st_ino==current.st_ino) unlink(path.fileSystemRepresentation);
    close(fd);
}
static NSDictionary *RPStageMutate(git_repository *repo,NSDictionary *q,BOOL unstage,BOOL commit,RPGitResources *c) {
    NSDictionary *initial=RPStageStatus(repo,q,c); RPStageExpected(repo,initial,q);
    if(!commit) RPStageSelected(initial,q,unstage);
    NSString *metadata=@(git_repository_path(repo)),*lock=[metadata stringByAppendingPathComponent:@"index.lock"];
    RPLeaseBegin(metadata,RPHead(repo,c),c);
    int fd=open(lock.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600);
    RPRequire(fd>=0,@"暂存区被其他工具锁定，未删除或改动原锁。");
    NSString *temporary=nil,*journal=[metadata stringByAppendingPathComponent:@"repopocket-transaction.json"]; BOOL began=NO;
    @try {
        RPLeaseCapture(metadata,@"index.lock",YES,c);
        NSDictionary *status=RPStageStatus(repo,q,c); RPStageExpected(repo,status,q);
        git_reference *head=RPHead(repo,c); git_transaction *tx=RPLockHead(repo,head,c);
        RPExpected(RPStatus(repo,c),q);
        git_index *index=RPStageIndex(repo,c); git_tree *before=RPTree(repo,head,c);
        NSArray *selected=commit ? status[@"staged"] : RPStageSelected(status,q,unstage);
        RPRequire(selected.count>0,@"没有可提交的已暂存内容。");
        if(commit) {
            // Validate every staged change, not working bytes; later unstaged edits are deliberately ignored.
            for(NSDictionary *row in selected) RPRequire(![row[@"blocked"] length],@"已暂存列表包含不受支持的文件，未提交。");
            for(size_t i=0;i<git_index_entrycount(index);i++) RPStageFilter(repo,@(git_index_get_byindex(index,i)->path));
        } else for(NSDictionary *row in selected) {
            NSString *path=row[@"path"]; RPStageFilter(repo,path);
            if(unstage) {
                git_tree_entry *original=NULL; int result=git_tree_entry_bypath(&original,before,path.UTF8String);
                if(result==GIT_ENOTFOUND) { RPCheck(git_index_remove_bypath(index,path.UTF8String),@"无法移除新增暂存项。"); }
                else {
                    RPCheck(result,@"无法读取 HEAD 文件。");
                    @try {
                        unsigned mode=git_tree_entry_filemode(original);
                        RPRequire(mode==GIT_FILEMODE_BLOB || mode==GIT_FILEMODE_BLOB_EXECUTABLE,@"HEAD 文件类型不受支持。");
                        git_index_entry restored={0}; restored.path=path.UTF8String;restored.mode=mode;git_oid_cpy(&restored.id,git_tree_entry_id(original));
                        RPCheck(git_index_add(index,&restored),@"无法还原 HEAD 暂存项。");
                    } @finally { git_tree_entry_free(original); }
                }
            } else if([row[@"fingerprint"] isEqual:@"missing"]) RPCheck(git_index_remove_bypath(index,path.UTF8String),@"无法暂存删除。");
            else RPCheck(git_index_add_bypath(index,path.UTF8String),@"无法暂存选中文件。");
        }
        temporary=RPStagePrepare(repo,index,c);
        // Re-read the on-disk state and worktree after preparing, before the single publication boundary.
        NSDictionary *fresh=RPStageStatus(repo,q,c); RPStageExpected(repo,fresh,q);
        if(!commit) RPStageSelected(fresh,q,unstage);
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"操作已取消，未发布暂存或提交。");
        if(!commit) {
            RPTestCrash(repo,q,@"stageBeforePublish");
            RPRequire(rename(temporary.fileSystemRepresentation,[[metadata stringByAppendingPathComponent:@"index"] fileSystemRepresentation])==0,@"暂存区原子更新失败，原内容未更改。");
            RPTestCrash(repo,q,@"stageAfterPublish");
            return @{@"head":status[@"head"]};
        }
        git_oid treeID,commitID;RPCheck(git_index_write_tree_to(&treeID,index,repo),@"无法保存已暂存文件树。");
        RPRequire(!git_oid_equal(&treeID,git_tree_id(before)),@"没有已暂存内容变化。");
        git_tree *tree=NULL;git_commit *parent=NULL;git_signature *author=NULL;
        RPCheck(git_tree_lookup(&tree,repo,&treeID),@"无法读取暂存树。");KEEP(tree,git_tree_free);
        RPCheck(git_commit_lookup(&parent,repo,git_reference_target(head)),@"无法读取父提交。");KEEP(parent,git_commit_free);
        RPCheck(git_signature_now(&author,RPString(q,@"authorName").UTF8String,RPString(q,@"authorEmail").UTF8String),@"作者姓名或邮箱无效。");KEEP(author,git_signature_free);
        const git_commit *parents[]={parent};
        RPCheck(git_commit_create(&commitID,repo,NULL,author,author,"UTF-8",RPString(q,@"message").UTF8String,tree,1,parents),@"无法创建暂存提交。");
        RPStageExpected(repo,RPStageStatus(repo,q,c),q);
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"提交已取消，未更新分支。");
        RPTestCrash(repo,q,@"beforeJournal");
        // Same commit recovery contract: index already equals newTree, so recovery never replaces work files.
        NSDictionary *intent=@{@"operation":@"commit",@"reference":status[@"reference"],@"oldHead":status[@"head"],@"newHead":RPOID(&commitID),@"preparedIndex":temporary.lastPathComponent};
        RPRequire([[NSJSONSerialization dataWithJSONObject:intent options:0 error:nil] writeToFile:journal options:NSDataWritingAtomic error:nil],@"无法保存提交恢复记录。");began=YES;
        RPCheck(git_transaction_set_target(tx,git_reference_name(head),&commitID,author,"RepoPocket staged commit"),@"准备分支更新失败，恢复证据已保留。");
        RPCheck(git_transaction_commit(tx),@"分支更新中断，恢复证据已保留。");
        RPTestCrash(repo,q,@"afterPublish");
        RPRequire(unlink(journal.fileSystemRepresentation)==0,@"提交已完成，恢复记录仍保留，请检查。");began=NO;
        return @{@"commit":RPOID(&commitID),@"head":RPOID(&commitID)};
    } @finally {
        if(!began && temporary) unlink(temporary.fileSystemRepresentation);
        RPStageUnlock(lock,fd);
    }
}
static NSDictionary *RPCommitStaged(git_repository *repo,NSDictionary *q,RPGitResources *c) { return RPStageMutate(repo,q,NO,YES,c); }
static NSDictionary *RPStageDiff(git_repository *repo,NSDictionary *q,RPGitResources *c) {
    NSDictionary *status=RPStageStatus(repo,q,c);RPStageExpected(repo,status,q);
    NSString *side=RPString(q,@"side"),*path=RPString(q,@"path");BOOL staged=[side isEqual:@"staged"];
    RPRequire(staged || [side isEqual:@"unstaged"],@"差异方向无效。");RPPath(@(git_repository_workdir(repo)),path,YES);
    RPStageSelected(status,@{@"files":@[@{@"path":path,@"fingerprint":RPString(q,@"fingerprint")}]},staged);
    git_index *index=RPStageIndex(repo,c);git_diff *diff=NULL;git_diff_options options=GIT_DIFF_OPTIONS_INIT;
    options.flags=GIT_DIFF_INCLUDE_UNTRACKED|GIT_DIFF_RECURSE_UNTRACKED_DIRS|GIT_DIFF_SHOW_UNTRACKED_CONTENT|GIT_DIFF_DISABLE_PATHSPEC_MATCH;
    options.max_size=256*1024;char *one=(char *)path.UTF8String;options.pathspec.strings=&one;options.pathspec.count=1;
    if(staged) RPCheck(git_diff_tree_to_index(&diff,repo,RPTree(repo,RPHead(repo,c),c),index,&options),@"无法读取 HEAD → 暂存区差异。");
    else RPCheck(git_diff_index_to_workdir(&diff,repo,index,&options),@"无法读取暂存区 → 工作区差异。");KEEP(diff,git_diff_free);
    NSDictionary *serialized=RPSerializeDiff(diff,NO,q);NSMutableString *text=[NSMutableString new];BOOL binary=NO;
    for(NSDictionary *file in serialized[@"files"]) { if(file[@"patch"]==NSNull.null) binary=YES;else [text appendString:file[@"patch"]]; }
    NSDictionary *fresh=RPStageStatus(repo,q,c);RPStageExpected(repo,fresh,q);
    RPStageSelected(fresh,@{@"files":@[@{@"path":path,@"fingerprint":RPString(q,@"fingerprint")}]},staged);
    return @{@"text":text,@"binary":@(binary),@"truncated":serialized[@"truncated"]};
}
