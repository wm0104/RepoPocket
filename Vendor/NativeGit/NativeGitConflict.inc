// Persistent, bounded merge sessions. Resolutions stay in the index until explicit continue.
static NSString *RPConflictPath(git_repository *repo) {
    return RPPath(@(git_repository_path(repo)),@"repopocket-merge.json",YES);
}
static void RPConflictSave(git_repository *repo,NSDictionary *record) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    RPRequire(bytes && bytes.length<=8*1024*1024 && [bytes writeToFile:RPConflictPath(repo) options:NSDataWritingAtomic error:nil],@"无法保存本地合并会话；未继续修改。");
}
static NSMutableDictionary *RPConflictRead(git_repository *repo) {
    NSData *bytes=[NSData dataWithContentsOfFile:RPConflictPath(repo)];
    RPRequire(bytes && bytes.length<=8*1024*1024,@"没有可恢复的 RepoPocket 合并会话，或记录超过预算。");
    id value=[NSJSONSerialization JSONObjectWithData:bytes options:NSJSONReadingMutableContainers error:nil];
    RPRequire([value isKindOfClass:NSDictionary.class] && [value[@"version"] isEqual:@1] && [value[@"files"] isKindOfClass:NSArray.class] && [value[@"files"] count]<=200,@"合并会话损坏，未改动任何文件；请使用桌面 Git 检查。");
    return value;
}
static NSString *RPConflictOwnedPath(git_repository *repo,NSString *name) {
    RPRequire([name isKindOfClass:NSString.class] && [name hasPrefix:@"repopocket-merge-"] && ![name containsString:@"/"] && ![name containsString:@".."],@"合并快照路径无效。");
    return RPPath(@(git_repository_path(repo)),name,YES);
}
static NSDictionary *RPConflictEntry(const git_index_entry *entry) {
    if (!entry) return @{};
    RPRequire(entry->mode==GIT_FILEMODE_BLOB || entry->mode==GIT_FILEMODE_BLOB_EXECUTABLE,@"冲突包含符号链接、目录或子模块，请使用桌面 Git。");
    NSString *path=[NSString stringWithUTF8String:entry->path];
    RPRequire(path!=nil,@"冲突路径不是 UTF-8，请使用桌面 Git。");
    return @{@"path":path,@"oid":RPOID(&entry->id),@"mode":@(entry->mode)};
}
static git_tree *RPConflictTree(git_repository *repo,NSString *sha,RPGitResources *c) {
    git_oid oid;RPCheck(git_oid_fromstr(&oid,sha.UTF8String),@"合并提交标识损坏。");
    git_commit *commit=NULL;RPCheck(git_commit_lookup(&commit,repo,&oid),@"合并提交不可读取。");KEEP(commit,git_commit_free);
    git_tree *tree=NULL;RPCheck(git_commit_tree(&tree,commit),@"合并文件树不可读取。");KEEP(tree,git_tree_free);return tree;
}
static void RPConflictCollect(git_repository *repo,git_tree *tree,NSString *prefix,NSMutableDictionary *snapshots,NSDictionary *q) {
    for (size_t i=0;i<git_tree_entrycount(tree);i++) {
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"合并已取消。");
        const git_tree_entry *entry=git_tree_entry_byindex(tree,i);
        NSString *name=[NSString stringWithUTF8String:git_tree_entry_name(entry)];RPRequire(name!=nil,@"文件名不是 UTF-8。");
        NSString *path=[prefix stringByAppendingString:name];
        if (git_tree_entry_type(entry)==GIT_OBJECT_TREE) {
            git_tree *child=NULL;RPCheck(git_tree_lookup(&child,repo,git_tree_entry_id(entry)),@"读取快照树失败。");
            @try { RPConflictCollect(repo,child,[path stringByAppendingString:@"/"],snapshots,q); } @finally { git_tree_free(child); }
        } else if (!snapshots[path]) {
            RPRequire(snapshots.count<10000,@"合并前后路径合计超过 10000 项，请使用桌面 Git。");
            snapshots[path]=RPFingerprint(@(git_repository_workdir(repo)),path);
        }
    }
}
static NSString *RPConflictIndexFingerprint(git_repository *repo) { return RPFingerprint(@(git_repository_path(repo)),@"index"); }
static git_index *RPConflictIndex(git_repository *repo,NSDictionary *record,RPGitResources *c) {
    NSString *fingerprint=RPConflictIndexFingerprint(repo);
    BOOL pending=[fingerprint isEqual:record[@"previousIndex"]];
    RPRequire(pending || [fingerprint isEqual:record[@"indexFingerprint"]],@"暂存区被外部工具修改，已拒绝覆盖；合并会话和所有文件已保留。");
    NSString *path=pending ? RPConflictOwnedPath(repo,record[@"preparedIndex"]) : [@(git_repository_path(repo)) stringByAppendingPathComponent:@"index"];
    git_index *index=NULL;RPCheck(git_index_open(&index,path.fileSystemRepresentation),@"无法读取合并暂存区。");KEEP(index,git_index_free);return index;
}
static NSString *RPConflictPrepareIndex(git_repository *repo,git_index *index,RPGitResources *c) {
    NSString *name=[@"repopocket-merge-index-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *path=RPConflictOwnedPath(repo,name);git_index *copy=NULL;
    RPCheck(git_index_open(&copy,path.fileSystemRepresentation),@"无法创建合并暂存区快照。");KEEP(copy,git_index_free);
    for (size_t i=0;i<git_index_entrycount(index);i++) RPCheck(git_index_add(copy,git_index_get_byindex(index,i)),@"无法复制合并暂存记录。");
    RPCheck(git_index_write(copy),@"无法保存合并暂存记录。");return name;
}
static void RPConflictInstall(git_repository *repo,NSMutableDictionary *record,NSString *prepared,NSDictionary *q) {
    NSString *metadata=@(git_repository_path(repo)),*path=RPConflictOwnedPath(repo,prepared);
    NSString *old=record[@"preparedIndex"];
    record[@"previousIndex"]=RPConflictIndexFingerprint(repo);
    record[@"indexFingerprint"]=RPFingerprint(metadata,prepared);record[@"preparedIndex"]=prepared;
    RPConflictSave(repo,record);
    RPTestCrash(repo,q,@"conflictBeforeIndex");
    // Keep the prepared snapshot until the next action: a crash before rename is replayable.
    NSData *bytes=[NSData dataWithContentsOfFile:path];
    RPRequire(bytes && [bytes writeToFile:[metadata stringByAppendingPathComponent:@"index"] options:NSDataWritingAtomic error:nil],@"合并记录已保存，暂存区安装中断；请重新进入合并页继续或中止。");
    RPTestCrash(repo,q,@"conflictAfterIndex");
    if (old && ![old isEqual:prepared]) unlink(RPConflictOwnedPath(repo,old).fileSystemRepresentation);
}
static int RPConflictLockIndex(git_repository *repo,RPGitResources *c) {
    NSString *metadata=@(git_repository_path(repo));NSString *lock=[metadata stringByAppendingPathComponent:@"index.lock"];
    int fd=open(lock.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY,0600);
    RPRequire(fd>=0,@"暂存区被其他工具锁定，未继续。");
    @try { RPLeaseCapture(metadata,@"index.lock",YES,c); } @catch(NSException *e) { close(fd);unlink(lock.fileSystemRepresentation);@throw; }
    return fd;
}
static void RPConflictCheckMarkers(git_repository *repo,NSDictionary *record) {
    NSString *path=RPPath(@(git_repository_path(repo)),@"MERGE_HEAD",YES);
    NSString *value=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    RPRequire(!value || [value isEqual:[record[@"sourceSHA"] stringByAppendingString:@"\n"]],@"MERGE_HEAD 被外部工具改变，未继续。");
    NSString *message=[NSString stringWithContentsOfFile:RPPath(@(git_repository_path(repo)),@"MERGE_MSG",YES) encoding:NSUTF8StringEncoding error:nil];
    RPRequire(!message || [message isEqual:[record[@"message"] stringByAppendingString:@"\n"]],@"MERGE_MSG 被外部工具改变，未覆盖其内容。");
    NSString *origPath=RPPath(@(git_repository_path(repo)),@"ORIG_HEAD",YES);
    NSString *orig=[NSString stringWithContentsOfFile:origPath encoding:NSUTF8StringEncoding error:nil];
    RPRequire([RPFingerprint(@(git_repository_path(repo)),@"ORIG_HEAD") isEqual:record[@"origHeadFingerprint"]] || [orig isEqual:[record[@"oldHead"] stringByAppendingString:@"\n"]],@"ORIG_HEAD 被外部工具改变，未覆盖。");
    int state=git_repository_state(repo);
    RPRequire(state==GIT_REPOSITORY_STATE_NONE || state==GIT_REPOSITORY_STATE_MERGE,@"仓库进入了另一种操作状态，已停止。");
}
static void RPConflictMarkers(git_repository *repo,NSDictionary *record) {
    RPConflictCheckMarkers(repo,record);
    NSString *metadata=@(git_repository_path(repo));
    RPRequire([[record[@"oldHead"] stringByAppendingString:@"\n"] writeToFile:RPPath(metadata,@"ORIG_HEAD",YES) atomically:YES encoding:NSUTF8StringEncoding error:nil],@"无法保存原生 ORIG_HEAD；合并会话已保留。");
    RPRequire([[record[@"sourceSHA"] stringByAppendingString:@"\n"] writeToFile:[metadata stringByAppendingPathComponent:@"MERGE_HEAD"] atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
              [[record[@"message"] stringByAppendingString:@"\n"] writeToFile:[metadata stringByAppendingPathComponent:@"MERGE_MSG"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"无法保存 Git 合并状态；会话已保留，请继续或中止。");
}
static NSDictionary *RPConflictBlob(git_repository *repo,NSDictionary *entry,RPGitResources *c) {
    if (![entry count]) return @{@"exists":@NO,@"binary":@NO,@"text":@"",@"oid":@""};
    git_oid oid;RPCheck(git_oid_fromstr(&oid,[entry[@"oid"] UTF8String]),@"冲突对象标识无效。");
    git_blob *blob=NULL;RPCheck(git_blob_lookup(&blob,repo,&oid),@"读取冲突内容失败。");KEEP(blob,git_blob_free);
    RPRequire(git_blob_rawsize(blob)<=2*1024*1024,@"冲突文件超过 2 MiB 预算。");
    NSString *text=nil;if (!git_blob_is_binary(blob)) text=[[NSString alloc] initWithBytes:git_blob_rawcontent(blob) length:(NSUInteger)git_blob_rawsize(blob) encoding:NSUTF8StringEncoding];
    return @{@"exists":@YES,@"binary":@(text==nil),@"text":text ?: @"",@"oid":entry[@"oid"]};
}
static void RPConflictWorktree(git_repository *repo,NSDictionary *record,git_index *result,BOOL allowResult,NSDictionary *q) {
    NSDictionary *snapshots=record[@"worktree"];
    RPRequire([snapshots isKindOfClass:NSDictionary.class] && snapshots.count<=10000,@"合并工作目录快照损坏。");
    for (NSString *path in snapshots) {
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"操作已取消，合并状态已保留。");
        NSString *actual=RPFingerprint(@(git_repository_workdir(repo)),path);
        if ([actual isEqual:snapshots[path]]) continue;
        const git_index_entry *entry=git_index_get_bypath(result,path.UTF8String,0);
        NSString *target=entry ? [NSString stringWithFormat:@"%@: %o",RPOID(&entry->id),entry->mode==GIT_FILEMODE_BLOB_EXECUTABLE ? 0111 : 0] : @"missing";
        RPRequire(allowResult && [actual isEqual:target],[@"合并期间工作文件被外部修改，拒绝覆盖：" stringByAppendingString:path]);
    }
}
static NSDictionary *RPConflictStatus(git_repository *repo,NSDictionary *q,RPGitResources *c) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:RPConflictPath(repo)]) return @{@"active":@NO};
    NSMutableDictionary *record=RPConflictRead(repo);RPConflictCheckMarkers(repo,record);
    git_reference *head=RPHead(repo,c);
    RPRequire([@(git_reference_name(head)) isEqual:record[@"reference"]] &&
        ([RPOID(git_reference_target(head)) isEqual:record[@"oldHead"]] || [RPOID(git_reference_target(head)) isEqual:record[@"newHead"]]),@"当前分支已被外部修改，合并会话已保留。");
    git_index *index=RPConflictIndex(repo,record,c);NSMutableArray *files=[NSMutableArray new];NSUInteger resolved=0;
    for (NSDictionary *row in record[@"files"]) {
        NSString *path=row[@"path"];BOOL done=git_index_get_bypath(index,path.UTF8String,1)==NULL && git_index_get_bypath(index,path.UTF8String,2)==NULL && git_index_get_bypath(index,path.UTF8String,3)==NULL;
        if (done) resolved++;
        [files addObject:@{@"path":path,@"resolved":@(done),@"oursExists":@([row[@"ours"] count]>0),@"theirsExists":@([row[@"theirs"] count]>0)}];
    }
    return @{@"active":@YES,@"session":record[@"session"],@"head":RPOID(git_reference_target(head)),@"reference":record[@"reference"],
        @"sourceRef":record[@"sourceRef"],@"sourceSHA":record[@"sourceSHA"],@"method":record[@"method"],@"phase":record[@"phase"],
        @"recoveryRef":record[@"recoveryRef"],@"indexFingerprint":RPConflictIndexFingerprint(repo),@"resolved":@(resolved),@"files":files};
}
static void RPConflictFilters(git_repository *repo,git_index *index,const git_oid *commitID,NSDictionary *q) {
    // Recovery fingerprints are raw worktree bytes. Refuse transformations instead of guessing them after a crash.
    for (size_t i=0;i<git_index_entrycount(index);i++) {
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"过滤属性检查已取消。");
        const git_index_entry *entry=git_index_get_byindex(index,i);git_blob *blob=NULL;
        RPCheck(git_blob_lookup(&blob,repo,&entry->id),@"无法检查合并文件过滤属性。");
        @try {
            for (int pinned=0;pinned<2;pinned++) {
                git_blob_filter_options options=GIT_BLOB_FILTER_OPTIONS_INIT;
                // Binary short-circuit returns an empty buffer, not the original bytes.
                // Apply the actual filter path so transformations still fail the byte check.
                options.flags &= ~GIT_BLOB_FILTER_CHECK_FOR_BINARY;
                if (pinned) { options.flags |= GIT_BLOB_FILTER_ATTRIBUTES_FROM_COMMIT;options.attr_commit_id=*commitID; }
                git_buf filtered=GIT_BUF_INIT;
                @try {
                    RPCheck(git_blob_filter(&filtered,blob,entry->path,&options),@"无法安全检查 checkout 过滤属性，请使用桌面 Git。");
                    RPRequire(filtered.size==git_blob_rawsize(blob) && (!filtered.size || memcmp(filtered.ptr,git_blob_rawcontent(blob),filtered.size)==0),@"此合并涉及 CRLF、ident 或其他会改变文件字节的 checkout 过滤；为保证中止逐字节恢复，请使用桌面 Git，尚未签出文件。");
                } @finally { git_buf_dispose(&filtered); }
            }
        } @finally { git_blob_free(blob); }
    }
}
static NSDictionary *RPConflictStart(git_repository *repo,NSDictionary *q,git_index *merged,git_reference *head,git_reference *source,git_tree *before,git_tree *incoming,RPMergeODB *overlay,RPGitResources *c) {
    NSMutableArray *files=[NSMutableArray new];git_index_conflict_iterator *it=NULL;
    RPCheck(git_index_conflict_iterator_new(&it,merged),@"无法读取冲突。");KEEP(it,git_index_conflict_iterator_free);
    const git_index_entry *a,*o,*t;int rc;
    while ((rc=git_index_conflict_next(&a,&o,&t,it))==0) {
        RPRequire(files.count<200,@"冲突超过 200 个文件，请使用桌面 Git；尚未开始合并。");
        NSDictionary *ancestor=RPConflictEntry(a),*ours=RPConflictEntry(o),*theirs=RPConflictEntry(t);NSString *path=(ours[@"path"] ?: theirs[@"path"] ?: ancestor[@"path"]);
        for (NSDictionary *entry in @[ancestor,ours,theirs]) RPRequire(!entry.count || [entry[@"path"] isEqual:path],@"跨路径 rename 冲突不能安全按单文件解决，请使用桌面 Git；尚未开始合并。");
        [files addObject:@{@"path":path,@"ancestor":ancestor,@"ours":ours,@"theirs":theirs}];
    }
    RPRequire(rc==GIT_ITEROVER && files.count>0,@"没有可开始的文件冲突。");
    // Rename detection is intentionally disabled by RPMerge: rename/delete is a deletion plus an explicit added path.
    git_tree *trees[]={before,incoming};
    for (int i=0;i<2;i++) {
        git_index *treeIndex=NULL;RPCheck(git_index_new(&treeIndex),@"无法检查合并文件过滤属性。");KEEP(treeIndex,git_index_free);
        RPCheck(git_index_read_tree(treeIndex,trees[i]),@"无法读取过滤检查文件树。");
        RPConflictFilters(repo,treeIndex,i==0 ? git_reference_target(head) : git_reference_target(source),q);
    }
    NSMutableDictionary *snapshots=[NSMutableDictionary new];RPConflictCollect(repo,before,@"",snapshots,q);RPConflictCollect(repo,incoming,@"",snapshots,q);
    NSString *metadata=@(git_repository_path(repo));git_transaction *tx=RPLockHead(repo,head,c);
    RPCheck(git_transaction_lock_ref(tx,"ORIG_HEAD"),@"ORIG_HEAD 被其他工具锁定。");RPLeaseCapture(metadata,@"ORIG_HEAD.lock",YES,c);
    RPCheck(git_transaction_lock_ref(tx,git_reference_name(source)),@"来源分支被锁定。");RPLeaseCapture(metadata,[@(git_reference_name(source)) stringByAppendingString:@".lock"],YES,c);
    int fd=RPConflictLockIndex(repo,c);
    @try {
        RPMergeClean(repo,q,c);
        for (NSString *name in @[@"MERGE_HEAD",@"MERGE_MSG",@"MERGE_MODE"]) RPRequire(![[NSFileManager defaultManager] fileExistsAtPath:RPPath(metadata,name,YES)],@"存在不属于本会话的 Git 合并标记，未覆盖；请先在原工具确认。");
        git_checkout_options check=GIT_CHECKOUT_OPTIONS_INIT;
        check.checkout_strategy=GIT_CHECKOUT_SAFE|GIT_CHECKOUT_DONT_OVERWRITE_IGNORED|GIT_CHECKOUT_DONT_UPDATE_INDEX|GIT_CHECKOUT_SKIP_UNMERGED|GIT_CHECKOUT_DRY_RUN;check.baseline=before;
        RPCheck(git_checkout_index(repo,merged,&check),@"非冲突结果会覆盖本地或忽略文件，尚未开始合并。");
        NSString *session=NSUUID.UUID.UUIDString,*backup=[@"repopocket-merge-original-" stringByAppendingString:session];
        NSData *bytes=[NSData dataWithContentsOfFile:[metadata stringByAppendingPathComponent:@"index"]];
        RPRequire(bytes && [bytes writeToFile:RPConflictOwnedPath(repo,backup) options:NSDataWritingAtomic error:nil],@"无法备份合并前暂存区。");
        NSString *prepared=RPConflictPrepareIndex(repo,merged,c),*recovery=[@"refs/repopocket/recovery/" stringByAppendingString:session];
        git_reference *saved=NULL;RPCheck(git_reference_create(&saved,repo,recovery.UTF8String,git_reference_target(head),0,"RepoPocket merge recovery"),@"无法保留合并前提交。");KEEP(saved,git_reference_free);
        // Keep the incoming commit alive even if its branch is moved or removed while the app is closed.
        NSString *incomingRef=[recovery stringByAppendingString:@"-incoming"];
        git_reference *kept=NULL;RPCheck(git_reference_create(&kept,repo,incomingRef.UTF8String,git_reference_target(source),0,"RepoPocket incoming recovery"),@"无法保留传入提交。");KEEP(kept,git_reference_free);
        for (NSDictionary *object in RPMergeObjects(overlay).allValues) {
            RPRequire(!RPIsCancelled(q[@"requestID"]),@"合并已取消，工作文件未修改。");NSData *data=object[@"data"];git_oid written;
            RPCheck(git_odb_write(&written,overlay->disk,data.bytes,data.length,[object[@"type"] intValue]),@"无法保存合并对象。");
        }
        NSData *origHead=[NSData dataWithContentsOfFile:RPPath(metadata,@"ORIG_HEAD",YES)];
        RPRequire(!origHead || origHead.length<=4096,@"现有 ORIG_HEAD 超过恢复预算，尚未开始合并。");
        NSMutableDictionary *record=[@{@"version":@1,@"session":session,@"reference":@(git_reference_name(head)),@"oldHead":RPOID(git_reference_target(head)),
            @"sourceRef":@(git_reference_name(source)),@"sourceSHA":RPOID(git_reference_target(source)),@"method":q[@"method"],@"message":q[@"message"] ?: @"Merge incoming changes",
            @"phase":@"resolving",@"origHead":origHead ? [origHead base64EncodedStringWithOptions:0] : @"",@"origHeadFingerprint":RPFingerprint(metadata,@"ORIG_HEAD"),@"files":files,@"worktree":snapshots,@"backup":backup,@"backupFingerprint":RPFingerprint(metadata,backup),@"recoveryRef":recovery} mutableCopy];
        RPConflictInstall(repo,record,prepared,q);RPConflictMarkers(repo,record);
        return @{@"head":record[@"oldHead"],@"mergePending":@YES};
    } @finally { close(fd);unlink([metadata stringByAppendingPathComponent:@"index.lock"].fileSystemRepresentation); }
}
static NSDictionary *RPConflictFile(git_repository *repo,NSDictionary *q,RPGitResources *c) {
    NSMutableDictionary *record=RPConflictRead(repo);
    RPRequire([record[@"session"] isEqual:RPString(q,@"session")] && [RPConflictIndexFingerprint(repo) isEqual:RPString(q,@"indexFingerprint")],@"合并会话或暂存区已变化，请返回重新核对。");
    RPConflictCheckMarkers(repo,record);
    RPExpected(@{@"head":RPOID(git_reference_target(RPHead(repo,c))),@"reference":@(git_reference_name(RPHead(repo,c)))},q);
    git_index *index=RPConflictIndex(repo,record,c);
    NSString *path=RPString(q,@"path");NSDictionary *row=nil;
    for (NSDictionary *candidate in record[@"files"]) if ([candidate[@"path"] isEqual:path]) { row=candidate;break; }
    RPRequire(row!=nil,@"此路径不属于当前合并冲突。");
    NSDictionary *ours=RPConflictBlob(repo,row[@"ours"],c),*theirs=RPConflictBlob(repo,row[@"theirs"],c),*ancestor=RPConflictBlob(repo,row[@"ancestor"],c);
    const git_index_entry *resolved=git_index_get_bypath(index,path.UTF8String,0);
    BOOL done=git_index_get_bypath(index,path.UTF8String,1)==NULL && git_index_get_bypath(index,path.UTF8String,2)==NULL && git_index_get_bypath(index,path.UTF8String,3)==NULL;
    NSDictionary *result=done ? RPConflictBlob(repo,RPConflictEntry(resolved),c) : ours;
    BOOL binary=[ours[@"binary"] boolValue] || [theirs[@"binary"] boolValue] || [ancestor[@"binary"] boolValue];
    NSString *text=result[@"text"];
    if (!done && !binary && [ours[@"exists"] boolValue] && [theirs[@"exists"] boolValue]) {
        git_index_entry a={0},o={0},t={0};
        NSDictionary *entries[]={row[@"ancestor"],row[@"ours"],row[@"theirs"]};git_index_entry *targets[]={&a,&o,&t};
        for (int i=0;i<3;i++) if ([entries[i] count]) {
            targets[i]->path=path.UTF8String;targets[i]->mode=[entries[i][@"mode"] unsignedIntValue];
            RPCheck(git_oid_fromstr(&targets[i]->id,[entries[i][@"oid"] UTF8String]),@"冲突对象标识损坏。");
        }
        git_merge_file_options options=GIT_MERGE_FILE_OPTIONS_INIT;options.our_label="CURRENT";options.their_label="INCOMING";options.ancestor_label="BASE";
        git_merge_file_result merged={0};
        RPCheck(git_merge_file_from_index(&merged,repo,[row[@"ancestor"] count] ? &a : NULL,&o,&t,&options),@"无法生成文本冲突块。");
        @try {
            RPRequire(merged.len<=2*1024*1024,@"文本合并结果超过 2 MiB。");
            text=[[NSString alloc] initWithBytes:merged.ptr length:merged.len encoding:NSUTF8StringEncoding];RPRequire(text!=nil,@"冲突结果不是 UTF-8，请选择一方内容。");
        } @finally { git_merge_file_result_free(&merged); }
    }
    return @{@"path":path,@"ours":ours,@"theirs":theirs,@"binary":@(binary),@"resolved":@(done),@"result":text ?: @"",@"resultOID":result[@"oid"],@"resultExists":done ? result[@"exists"] : @YES,@"indexFingerprint":RPConflictIndexFingerprint(repo)};
}
static void RPConflictCleanup(git_repository *repo,NSDictionary *record) {
    RPConflictCheckMarkers(repo,record);
    NSString *metadata=@(git_repository_path(repo));
    for (NSString *name in @[@"MERGE_HEAD",@"MERGE_MSG"]) {
        NSString *path=[metadata stringByAppendingPathComponent:name];
        RPRequire(unlink(path.fileSystemRepresentation)==0 || errno==ENOENT,@"合并已完成，但合并状态标记未清除；请重新进入后检查。");
    }
    if ([record[@"phase"] isEqual:@"aborting"]) {
        NSString *orig=RPPath(metadata,@"ORIG_HEAD",YES);
        if ([record[@"origHeadFingerprint"] isEqual:@"missing"]) RPRequire(unlink(orig.fileSystemRepresentation)==0 || errno==ENOENT,@"无法恢复合并前 ORIG_HEAD 缺省状态。");
        else {
            NSData *bytes=[[NSData alloc] initWithBase64EncodedString:record[@"origHead"] options:0];
            RPRequire(bytes && [bytes writeToFile:orig options:NSDataWritingAtomic error:nil],@"无法恢复合并前 ORIG_HEAD；会话保留供重试。");
        }
    }
    // Remove the session last. No unrelated untracked/ignored file is ever removed.
    RPRequire(unlink(RPConflictPath(repo).fileSystemRepresentation)==0,@"合并已完成，但会话清理失败。");
    unlink(RPConflictOwnedPath(repo,record[@"backup"]).fileSystemRepresentation);
    unlink(RPConflictOwnedPath(repo,record[@"preparedIndex"]).fileSystemRepresentation);
    (void)metadata;
}
static NSDictionary *RPConflictMutate(git_repository *repo,NSDictionary *q,NSString *operation,RPGitResources *c) {
    NSMutableDictionary *record=RPConflictRead(repo);RPConflictCheckMarkers(repo,record);
    RPRequire([record[@"session"] isEqual:RPString(q,@"session")],@"合并会话已改变，请重新进入。");
    RPRequire([RPConflictIndexFingerprint(repo) isEqual:RPString(q,@"indexFingerprint")],@"暂存区在预览后改变，请重新加载合并进度。");
    git_reference *head=RPHead(repo,c);RPExpected(@{@"head":RPOID(git_reference_target(head)),@"reference":@(git_reference_name(head))},q);
    RPRequire([@(git_reference_name(head)) isEqual:record[@"reference"]] && ([RPOID(git_reference_target(head)) isEqual:record[@"oldHead"]] ||
        ([operation isEqual:@"conflictContinue"] && [RPOID(git_reference_target(head)) isEqual:record[@"newHead"]])),@"合并分支已被外部改变，已拒绝。");
    git_index *index=RPConflictIndex(repo,record,c);
    BOOL continuing=[record[@"phase"] isEqual:@"continuing"] || [record[@"phase"] isEqual:@"aborting"];
    RPConflictWorktree(repo,record,index,continuing,q);
    NSString *metadata=@(git_repository_path(repo));
    RPRequire(![[NSFileManager defaultManager] fileExistsAtPath:[metadata stringByAppendingPathComponent:@"repopocket-transaction.json"]],@"存在另一项未完成事务，已停止合并。");
    RPTestCrash(repo,q,@"conflictBeforeHeadLock");
    RPClearStaleOwnedLocks(metadata,q);git_transaction *tx=RPLockHead(repo,head,c);
    RPCheck(git_transaction_lock_ref(tx,"ORIG_HEAD"),@"ORIG_HEAD 被其他工具锁定。");RPLeaseCapture(metadata,@"ORIG_HEAD.lock",YES,c);
    int fd=RPConflictLockIndex(repo,c);
    @try {
        git_reference *lockedHead=RPHead(repo,c);
        RPExpected(@{@"head":RPOID(git_reference_target(lockedHead)),@"reference":@(git_reference_name(lockedHead))},q);
        RPRequire([@(git_reference_name(lockedHead)) isEqual:@(git_reference_name(head))] && [@(git_reference_name(lockedHead)) isEqual:record[@"reference"]] &&
            ([RPOID(git_reference_target(lockedHead)) isEqual:record[@"oldHead"]] || ([operation isEqual:@"conflictContinue"] && [RPOID(git_reference_target(lockedHead)) isEqual:record[@"newHead"]])),@"获取锁之前分支或 HEAD 已改变，拒绝覆盖外部提交。");
        head=lockedHead;
        RPConflictCheckMarkers(repo,record);
        RPRequire([RPConflictIndexFingerprint(repo) isEqual:RPString(q,@"indexFingerprint")],@"获取锁之前暂存区已变化，请重新加载。");
        RPConflictWorktree(repo,record,index,continuing,q);
        if ([operation isEqual:@"conflictResolve"]) {
            RPRequire(!continuing,@"提交或中止已开始，不能再修改解决结果。");
            NSString *path=RPString(q,@"path"),*choice=RPString(q,@"choice");NSDictionary *row=nil;
            for (NSDictionary *item in record[@"files"]) if ([item[@"path"] isEqual:path]) {row=item;break;}
            RPRequire(row!=nil,@"不是当前会话中的冲突路径。");
            NSDictionary *entry=nil;git_oid blob;unsigned int mode=GIT_FILEMODE_BLOB;
            if ([choice isEqual:@"ours"] || [choice isEqual:@"theirs"]) entry=row[choice];
            else if ([choice isEqual:@"manual"]) {
                NSString *text=q[@"text"];RPRequire([text isKindOfClass:NSString.class],@"缺少文本结果。");
                NSData *bytes=[text dataUsingEncoding:NSUTF8StringEncoding];RPRequire(bytes && bytes.length<=2*1024*1024 && ![text containsString:[NSString stringWithFormat:@"%C",(unichar)0]],@"结果不是有效文本或超过 2 MiB。");
                RPRequire(![RPConflictBlob(repo,row[@"ours"],c)[@"binary"] boolValue] && ![RPConflictBlob(repo,row[@"theirs"],c)[@"binary"] boolValue],@"二进制或非 UTF-8 冲突只能明确选择一方。");
                for (NSString *line in [text componentsSeparatedByString:@"\n"]) RPRequire(![line hasPrefix:@"<<<<<<<"] && ![line hasPrefix:@"======="] && ![line hasPrefix:@">>>>>>>"] && ![line hasPrefix:@"|||||||"],@"结果仍包含冲突标记，请逐块解决后再标记。");
                RPCheck(git_blob_create_frombuffer(&blob,repo,bytes.bytes,bytes.length),@"无法保存解决后的文本。");
                mode=[row[@"ours"][@"mode"] unsignedIntValue] ?: ([row[@"theirs"][@"mode"] unsignedIntValue] ?: GIT_FILEMODE_BLOB);
                entry=@{@"oid":RPOID(&blob),@"mode":@(mode)};
            } else RPRequire([choice isEqual:@"delete"],@"未知解决方式。");
            int rc=git_index_conflict_remove(index,path.UTF8String);RPRequire(rc==0 || rc==GIT_ENOTFOUND,@"无法更新冲突记录。");
            rc=git_index_remove_bypath(index,path.UTF8String);RPRequire(rc==0 || rc==GIT_ENOTFOUND,@"无法更新结果记录。");
            if (entry.count) {
                git_index_entry result={0};result.path=path.UTF8String;result.mode=[entry[@"mode"] unsignedIntValue];
                RPCheck(git_oid_fromstr(&result.id,[entry[@"oid"] UTF8String]),@"结果对象无效。");RPCheck(git_index_add(index,&result),@"无法标记文件已解决。");
            }
            RPRequire(!RPIsCancelled(q[@"requestID"]),@"操作已取消，原解决进度保留。");
            RPConflictInstall(repo,record,RPConflictPrepareIndex(repo,index,c),q);RPConflictMarkers(repo,record);
            return RPConflictStatus(repo,q,c);
        }
        git_tree *before=RPConflictTree(repo,record[@"oldHead"],c);
        if ([operation isEqual:@"conflictContinue"] || [record[@"phase"] isEqual:@"continuing"]) {
            git_index *originalTree=NULL;RPCheck(git_index_new(&originalTree),@"无法核对恢复树过滤属性。");KEEP(originalTree,git_index_free);
            RPCheck(git_index_read_tree(originalTree,before),@"无法核对恢复树。");git_oid originalID;
            RPCheck(git_oid_fromstr(&originalID,[record[@"oldHead"] UTF8String]),@"恢复提交标识无效。");RPConflictFilters(repo,originalTree,&originalID,q);
        }
        if ([operation isEqual:@"conflictAbort"]) {
            RPRequire(![RPOID(git_reference_target(head)) isEqual:record[@"newHead"]],@"合并提交已发布到本地分支，不能再中止；请继续完成清理，不会自动推送。");
            NSString *backup=RPConflictOwnedPath(repo,record[@"backup"]);
            RPRequire([RPFingerprint(metadata,record[@"backup"]) isEqual:record[@"backupFingerprint"]],@"合并前暂存区快照被修改，已拒绝中止。");
            if ([record[@"phase"] isEqual:@"continuing"]) {
                git_oid treeID;RPCheck(git_index_write_tree_to(&treeID,index,repo),@"无法检查中断签出结果。");
                git_tree *result=NULL;RPCheck(git_tree_lookup(&result,repo,&treeID),@"无法读取中断结果树。");KEEP(result,git_tree_free);
                git_checkout_options checkout=GIT_CHECKOUT_OPTIONS_INIT;
                checkout.checkout_strategy=GIT_CHECKOUT_SAFE|GIT_CHECKOUT_DONT_OVERWRITE_IGNORED|GIT_CHECKOUT_DONT_UPDATE_INDEX|GIT_CHECKOUT_DRY_RUN;checkout.baseline=result;
                RPCheck(git_checkout_tree(repo,(git_object *)before,&checkout),@"中止会覆盖外部文件，已拒绝；文件和合并会话均已保留。");
                // Keep phase continuing while restoring: both old and result bytes remain admissible after a crash.
                checkout.checkout_strategy &= ~GIT_CHECKOUT_DRY_RUN;
                RPCheck(git_checkout_tree(repo,(git_object *)before,&checkout),@"中止签出中断，请重新进入后再次中止。");
            }
            record[@"phase"]=@"aborting";RPConflictSave(repo,record);
            NSString *restored=[@"repopocket-merge-index-" stringByAppendingString:NSUUID.UUID.UUIDString];
            NSData *original=[NSData dataWithContentsOfFile:backup];
            RPRequire(original && [original writeToFile:RPConflictOwnedPath(repo,restored) options:NSDataWritingAtomic error:nil],@"无法准备合并前暂存区原始快照。");
            RPConflictInstall(repo,record,restored,q);
            RPConflictCleanup(repo,record);return @{@"head":record[@"oldHead"],@"mergePending":@NO,@"recoveryRef":record[@"recoveryRef"]};
        }
        RPRequire([operation isEqual:@"conflictContinue"] && ![record[@"phase"] isEqual:@"aborting"],@"中止已开始，请继续中止而不是生成提交。");
        RPRequire(!git_index_has_conflicts(index),@"仍有未解决文件，请逐个标记已解决后再继续。");
        git_oid treeID;RPCheck(git_index_write_tree_to(&treeID,index,repo),@"无法生成解决结果树。");
        git_tree *tree=NULL;RPCheck(git_tree_lookup(&tree,repo,&treeID),@"无法读取解决结果树。");KEEP(tree,git_tree_free);
        NSUInteger count=0;size_t bytes=0;RPMergeTreeBudget(repo,tree,q,&count,&bytes);
        git_oid newID;git_signature *author=NULL;
        RPCheck(git_signature_now(&author,RPString(q,@"authorName").UTF8String,RPString(q,@"authorEmail").UTF8String),@"请填写有效的提交作者姓名和邮箱。");KEEP(author,git_signature_free);
        if (record[@"newHead"]) RPCheck(git_oid_fromstr(&newID,[record[@"newHead"] UTF8String]),@"中断提交标识无效。");
        else {
            NSString *message=RPString(q,@"message");RPRequire([message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length>0,@"请填写合并提交说明。");
            git_oid oldID,sourceID;git_commit *ours=NULL,*theirs=NULL;
            RPCheck(git_oid_fromstr(&oldID,[record[@"oldHead"] UTF8String]),@"合并前提交无效。");RPCheck(git_oid_fromstr(&sourceID,[record[@"sourceSHA"] UTF8String]),@"来源提交无效。");
            RPCheck(git_commit_lookup(&ours,repo,&oldID),@"无法读取当前父提交。");KEEP(ours,git_commit_free);
            RPCheck(git_commit_lookup(&theirs,repo,&sourceID),@"无法读取传入父提交。");KEEP(theirs,git_commit_free);
            const git_commit *parents[]={ours,theirs};RPCheck(git_commit_create(&newID,repo,NULL,author,author,"UTF-8",message.UTF8String,tree,[record[@"method"] isEqual:@"squash"] ? 1 : 2,parents),@"无法创建本地合并提交。");
            record[@"newHead"]=RPOID(&newID);
        }
        RPConflictFilters(repo,index,&newID,q);
        git_checkout_options checkout=GIT_CHECKOUT_OPTIONS_INIT;
        checkout.checkout_strategy=GIT_CHECKOUT_SAFE|GIT_CHECKOUT_DONT_OVERWRITE_IGNORED|GIT_CHECKOUT_DONT_UPDATE_INDEX|GIT_CHECKOUT_DRY_RUN;checkout.baseline=before;
        RPCheck(git_checkout_index(repo,index,&checkout),@"结果签出会覆盖外部内容，已拒绝；请先保留并处理该内容。");
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"继续已取消，解决进度保留。");
        record[@"phase"]=@"continuing";RPConflictSave(repo,record);RPConflictMarkers(repo,record);
        checkout.checkout_strategy &= ~GIT_CHECKOUT_DRY_RUN;
        RPCheck(git_checkout_index(repo,index,&checkout),@"结果签出中断，合并会话保留；请重新进入继续或中止。");
        RPTestCrash(repo,q,@"conflictAfterCheckout");
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"签出后取消，合并会话保留；可以继续或安全中止。");
        if (![RPOID(git_reference_target(head)) isEqual:record[@"newHead"]]) {
            RPCheck(git_transaction_set_target(tx,git_reference_name(head),&newID,author,"RepoPocket resolved merge"),@"无法发布本地合并提交。");
#ifdef RP_GIT_TESTING
            if ([q[@"testCrashStage"] isEqual:@"conflictBeforePublishRename"]) {
                // Reproduce libgit2's durable lock bytes immediately before its ref rename; preserve the leased inode.
                NSString *lock=[metadata stringByAppendingPathComponent:[@(git_reference_name(head)) stringByAppendingString:@".lock"]];
                NSData *target=[[RPOID(&newID) stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
                int descriptor=open(lock.fileSystemRepresentation,O_WRONLY|O_TRUNC);RPRequire(descriptor>=0,@"无法设置发布前测试窗口。");
                ssize_t wrote=write(descriptor,target.bytes,target.length);close(descriptor);RPRequire(wrote==(ssize_t)target.length,@"发布前测试写入不完整。");
                RPTestCrash(repo,q,@"conflictBeforePublishRename");
            }
#endif
            RPCheck(git_transaction_commit(tx),@"发布中断，合并会话保留。");
        }
        RPTestCrash(repo,q,@"conflictAfterPublish");
        // A pending prepared index may not have reached disk before a previous process was killed.
        NSData *prepared=[NSData dataWithContentsOfFile:RPConflictOwnedPath(repo,record[@"preparedIndex"])];
        RPRequire(prepared && [prepared writeToFile:[metadata stringByAppendingPathComponent:@"index"] options:NSDataWritingAtomic error:nil],@"提交已保存在本地，但暂存区更新中断；请重新继续。");
        RPConflictCleanup(repo,record);return @{@"head":RPOID(&newID),@"commit":RPOID(&newID),@"mergePending":@NO,@"recoveryRef":record[@"recoveryRef"]};
    } @finally { close(fd);unlink([metadata stringByAppendingPathComponent:@"index.lock"].fileSystemRepresentation); }
}
static NSDictionary *RPConflictPull(git_repository *repo,NSMutableDictionary *q,RPGitResources *c) {
    git_reference *head=RPHead(repo,c),*source=RPSafeUpstream(repo,head,YES,c);
    NSMutableDictionary *request=[q mutableCopy];request[@"sourceRef"]=@(git_reference_name(source));request[@"sourceSHA"]=RPOID(git_reference_target(source));
    request[@"method"]=@"ordinary";request[@"pullMerge"]=@YES;request[@"startConflicts"]=@YES;
    request[@"message"]=q[@"message"] ?: @"Merge origin into current branch";
    return RPMerge(repo,request,YES,c);
}
