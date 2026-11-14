// Included by NativeGitBridge.m: shares the same guards, locks and bounded in-memory ODB.
static void RPHistoryClean(git_repository *repo, NSDictionary *q, RPGitResources *c) {
    NSDictionary *status=RPStatus(repo,c); RPExpected(status,q); RPWritable(repo,status);
    RPRequire([status[@"files"] count]==0,@"历史操作要求工作目录和暂存区干净（包括未跟踪文件），不会自动清理或暂存。");
    RPRequire(!RPIsCancelled(q[@"requestID"]),@"历史操作已取消。");
}
static void RPHistoryFetch(git_repository *repo, NSMutableDictionary *q, RPGitResources *c) {
    git_strarray names={0}; RPCheck(git_remote_list(&names,repo),@"无法核对其他远端。");
    BOOL onlyOrigin=names.count==1 && strcmp(names.strings[0],"origin")==0; git_strarray_dispose(&names);
    RPRequire(onlyOrigin,@"存在其他远端或没有 origin，无法确认从未推送；已拒绝改写历史。");
    git_remote *remote=RPRemote(repo,q,c);
    git_fetch_options options=GIT_FETCH_OPTIONS_INIT;
    options.callbacks=RPCallbacks(q); options.follow_redirects=GIT_REMOTE_REDIRECT_NONE;
    options.download_tags=GIT_REMOTE_DOWNLOAD_TAGS_NONE;
    char *raw[]={"+refs/heads/*:refs/remotes/origin/*","+refs/tags/*:refs/repopocket/fetched-tags/*"};
    git_strarray specs={raw,2};
    RPCheck(git_remote_fetch(remote,&specs,&options,"RepoPocket history safety fetch"),@"无法获取新鲜远端 heads/tags，未改写本地历史。");
}
static NSSet *RPHistoryPublished(git_repository *repo,NSDictionary *q,RPGitResources *c) {
    git_revwalk *walk=NULL; RPCheck(git_revwalk_new(&walk,repo),@"无法核对远端历史。"); KEEP(walk,git_revwalk_free);
    git_reference_iterator *iterator=NULL;
    RPCheck(git_reference_iterator_new(&iterator,repo),@"无法核对已发布历史。"); KEEP(iterator,git_reference_iterator_free);
    git_reference *ref=NULL; int rc; NSUInteger count=0;
    while ((rc=git_reference_next(&ref,iterator))==0) {
        @try {
            RPRequire(++count<=4000 && !RPIsCancelled(q[@"requestID"]),@"引用超过预算或操作已取消。");
            NSString *name=@(git_reference_name(ref));
            if (![name hasPrefix:@"refs/remotes/"] && ![name hasPrefix:@"refs/repopocket/fetched-tags/"] && ![name hasPrefix:@"refs/tags/"]) continue;
            git_object *object=NULL;
            RPCheck(git_reference_peel(&object,ref,GIT_OBJECT_COMMIT),@"远端或标签无法解析为提交，不能确认未推送。");
            @try { RPCheck(git_revwalk_push(walk,git_object_id(object)),@"无法读取远端历史。"); }
            @finally { git_object_free(object); }
        } @finally { git_reference_free(ref); }
    }
    RPRequire(rc==GIT_ITEROVER,@"远端引用读取不完整，已停止。");
    NSMutableSet *published=[NSMutableSet new]; git_oid oid;
    while ((rc=git_revwalk_next(&oid,walk))==0) {
        RPRequire(published.count<2000 && !RPIsCancelled(q[@"requestID"]),@"远端完整历史超过 2000 条或操作已取消，已拒绝改写。");
        [published addObject:RPOID(&oid)];
    }
    RPRequire(rc==GIT_ITEROVER,@"远端历史不完整，不能确认未推送。");
    return published;
}
static NSDictionary *RPHistoryEdit(git_repository *repo, NSMutableDictionary *q, BOOL apply, RPGitResources *c) {
    NSString *kind=RPString(q,@"kind");
    BOOL revert=[kind isEqual:@"revert"], keep=[kind isEqual:@"removeKeep"], discard=[kind isEqual:@"removeDiscard"], squash=[kind isEqual:@"squash"];
    RPRequire(revert || keep || discard || squash,@"未知的历史操作。");
    RPHistoryClean(repo,q,c);
    git_reference *head=RPHead(repo,c);
    git_commit *ours=NULL; git_tree *before=NULL;
    RPCheck(git_commit_lookup(&ours,repo,git_reference_target(head)),@"读取当前提交失败。"); KEEP(ours,git_commit_free);
    RPCheck(git_commit_tree(&before,ours),@"读取当前文件树失败。"); KEEP(before,git_tree_free);
    // Revert is additive. Rewriting is allowed only after a successful fresh fetch,
    // with a same-name origin upstream; no-upstream/offline is deliberately denied.
    NSString *upstreamSHA=@"";
    git_reference *upstream=NULL;
    if (!revert) {
        RPRequire(!git_repository_is_shallow(repo),@"浅克隆不能证明提交未推送，已拒绝修改历史。");
        RPSafeUpstream(repo,head,YES,c);
        RPHistoryFetch(repo,q,c);
        RPHistoryClean(repo,q,c);
        upstream=RPSafeUpstream(repo,head,YES,c);
        upstreamSHA=RPOID(git_reference_target(upstream));
        if (apply) RPRequire([upstreamSHA isEqual:RPString(q,@"expectedUpstream")],@"远端在预览后变化，请重新预览；未修改本地历史。");
    }
    NSSet *published=revert ? nil : RPHistoryPublished(repo,q,c);
    RPMergeODB *overlay=RPMergeOverlay(repo,c);
    git_commit *target=NULL,*parent=NULL;
    git_index *result=NULL;
    git_tree *resultTree=NULL;
    NSMutableArray *removed=[NSMutableArray new];
    if (revert) {
        NSString *sha=RPString(q,@"sha"); git_oid oid;
        RPRequire(sha.length==GIT_OID_HEXSZ,@"提交标识无效。"); RPCheck(git_oid_fromstr(&oid,sha.UTF8String),@"提交标识无效。");
        RPCheck(git_commit_lookup(&target,repo,&oid),@"找不到要反向提交的记录。"); KEEP(target,git_commit_free);
        RPRequire(git_commit_parentcount(target)==1,@"合并提交需要主线选择，根提交需要专门预览；当前不支持这两种反向提交。");
        RPRequire(git_oid_equal(&oid,git_commit_id(ours)) || git_graph_descendant_of(repo,git_commit_id(ours),&oid)==1,@"只能反向提交当前分支可达的记录。");
        RPMergeHistory(repo,git_commit_id(ours),&oid,q,c);
        git_tree *targetTree=NULL,*parentTree=NULL;
        RPCheck(git_commit_tree(&targetTree,target),@"读取反向提交文件树失败。"); KEEP(targetTree,git_tree_free);
        RPCheck(git_commit_parent(&parent,target,0),@"读取原提交父节点失败。"); KEEP(parent,git_commit_free);
        RPCheck(git_commit_tree(&parentTree,parent),@"读取父节点文件树失败。"); KEEP(parentTree,git_tree_free);
        for (NSValue *value in @[[NSValue valueWithPointer:before],[NSValue valueWithPointer:targetTree],[NSValue valueWithPointer:parentTree]]) {
            NSUInteger count=0; size_t bytes=0; RPMergeTreeBudget(repo,value.pointerValue,q,&count,&bytes);
        }
        git_merge_options options=GIT_MERGE_OPTIONS_INIT;
        options.flags=GIT_MERGE_SKIP_REUC|GIT_MERGE_NO_RECURSIVE;
        RPCheck(git_revert_commit(&result,repo,target,ours,0,&options),@"无法计算反向提交，未修改原仓库。"); KEEP(result,git_index_free);
        RPRequire(!git_index_has_conflicts(result),@"此反向提交会发生冲突，已在内存预检拒绝；未开始 revert，原工作区、暂存区和分支保持不变。");
        git_oid treeID;
        RPCheck(git_index_write_tree_to(&treeID,result,repo),@"准备反向提交文件树失败。");
        RPRequire(!git_oid_equal(&treeID,git_tree_id(before)),@"反向提交不会产生内容变化，已拒绝创建空提交。");
        RPCheck(git_tree_lookup(&resultTree,repo,&treeID),@"读取反向提交结果失败。"); KEEP(resultTree,git_tree_free);
        [removed addObject:RPOID(&oid)];
    } else {
        id raw=q[@"count"]; NSInteger count=[raw isKindOfClass:NSNumber.class] ? [raw integerValue] : 0;
        RPRequire(count>0 && count<=100 && [raw doubleValue]==count && (squash ? count>=2 : count==1),@"仅允许移除顶部一条，或压缩顶部连续 2 至 100 条提交。");
        RPMergeHistory(repo,git_commit_id(ours),git_reference_target(upstream),q,c);
        git_commit *cursor=ours;
        for (NSInteger i=0;i<count;i++) {
            RPRequire(git_commit_parentcount(cursor)==1,@"范围包含合并或根提交，已拒绝改写历史。");
            const git_oid *oid=git_commit_id(cursor);
            RPRequire(!git_oid_equal(oid,git_reference_target(upstream)) && git_graph_descendant_of(repo,git_reference_target(upstream),oid)==0,@"范围包含远端可达提交，不能证明未推送，已拒绝改写。");
            RPRequire(![published containsObject:RPOID(oid)],@"范围包含远端或标签可达记录，不能确认未推送，已拒绝改写。");
            [removed addObject:RPOID(oid)];
            git_commit *next=NULL; RPCheck(git_commit_parent(&next,cursor,0),@"读取顶部连续提交失败。"); KEEP(next,git_commit_free); cursor=next;
        }
        parent=cursor;
        // Require the upstream to be an ancestor of the retained parent, not a
        // divergent branch or an inferred publication state from cached refs.
        RPRequire(git_oid_equal(git_commit_id(parent),git_reference_target(upstream)) || git_graph_descendant_of(repo,git_commit_id(parent),git_reference_target(upstream))==1,@"远端分叉或范围越过远端边界，已拒绝改写历史。");
        if (squash) resultTree=before;
        else { RPCheck(git_commit_tree(&resultTree,parent),@"读取保留节点文件树失败。"); KEEP(resultTree,git_tree_free); }
        NSUInteger countBudget=0; size_t bytes=0; RPMergeTreeBudget(repo,before,q,&countBudget,&bytes);
        countBudget=0; bytes=0; RPMergeTreeBudget(repo,resultTree,q,&countBudget,&bytes);
        RPCheck(git_index_new(&result),@"无法准备历史操作暂存区。"); KEEP(result,git_index_free);
        RPCheck(git_index_read_tree(result,resultTree),@"无法准备结果暂存区。");
    }
    RPCommitDiffBudget bounds={0,0,NO,q[@"requestID"]};
    git_diff_options diffOptions=GIT_DIFF_OPTIONS_INIT;
    diffOptions.notify_cb=RPCommitDiffNotify; diffOptions.progress_cb=RPCommitDiffProgress; diffOptions.payload=&bounds; diffOptions.max_size=256*1024;
    git_diff *diff=NULL; int rc=git_diff_tree_to_tree(&diff,repo,before,resultTree,&diffOptions); KEEP(diff,git_diff_free);
    if (!bounds.limited) RPCheck(rc,@"无法读取影响预览。");
    NSDictionary *serialized=RPSerializeDiff(diff,bounds.limited,q);
    NSMutableDictionary *preview=[@{@"head":RPOID(git_commit_id(ours)),@"reference":@(git_reference_name(head)),@"tree":RPOID(git_tree_id(resultTree)),@"upstream":upstreamSHA,@"commits":removed,@"files":serialized[@"files"],@"truncated":serialized[@"truncated"]} mutableCopy];
    RPHistoryClean(repo,q,c);
    git_checkout_options checkout=GIT_CHECKOUT_OPTIONS_INIT; checkout.baseline=before;
    checkout.checkout_strategy=GIT_CHECKOUT_SAFE|GIT_CHECKOUT_DONT_OVERWRITE_IGNORED|GIT_CHECKOUT_DONT_UPDATE_INDEX|GIT_CHECKOUT_DRY_RUN;
    if (revert || discard) RPCheck(git_checkout_index(repo,result,&checkout),@"历史操作会覆盖本地文件（包括忽略文件），已拒绝。");
    if (!apply) return preview;
    RPRequire([preview[@"tree"] isEqual:RPString(q,@"expectedTree")],@"预览结果变化，请重新确认。");
    git_signature *author=NULL;
    RPCheck(git_signature_now(&author,RPString(q,@"authorName").UTF8String,RPString(q,@"authorEmail").UTF8String),@"作者姓名或邮箱无效。"); KEEP(author,git_signature_free);
    git_oid newID;
    if (revert || squash) {
        NSString *message=RPString(q,@"message");
        RPRequire([message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length,@"提交说明不能为空。");
        const git_commit *parents[]={revert ? ours : parent};
        RPCheck(git_commit_create(&newID,repo,NULL,author,author,"UTF-8",message.UTF8String,resultTree,1,parents),@"准备新提交失败。");
    } else git_oid_cpy(&newID,git_commit_id(parent));
    NSString *metadata=@(git_repository_path(repo));
    git_transaction *tx=RPLockHead(repo,head,c);
    NSString *indexLock=[metadata stringByAppendingPathComponent:@"index.lock"];
    int fd=open(indexLock.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY,0600);
    RPRequire(fd>=0,@"暂存区被其他工具锁定。"); close(fd);
    NSString *temporary=[metadata stringByAppendingPathComponent:[@"repopocket-index-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *journal=[metadata stringByAppendingPathComponent:@"repopocket-transaction.json"];
    BOOL began=NO;
    @try {
        RPLeaseCapture(metadata,@"index.lock",YES,c); RPHistoryClean(repo,q,c);
        if (!revert) RPRequire([RPOID(git_reference_target(RPSafeUpstream(repo,RPHead(repo,c),YES,c))) isEqual:upstreamSHA],@"远端跟踪引用已变化，请重新预览。");
        if (revert || discard) RPCheck(git_checkout_index(repo,result,&checkout),@"预览后文件已变化，已停止。");
        git_index *prepared=NULL; RPCheck(git_index_open(&prepared,temporary.fileSystemRepresentation),@"无法准备结果暂存区。"); KEEP(prepared,git_index_free);
        for (size_t i=0;i<git_index_entrycount(result);i++) RPCheck(git_index_add(prepared,git_index_get_byindex(result,i)),@"无法准备结果记录。");
        RPCheck(git_index_write(prepared),@"无法保存结果暂存区。");
        for (NSDictionary *row in RPMergeObjects(overlay).allValues) {
            NSData *data=row[@"data"]; git_oid written;
            RPCheck(git_odb_write(&written,overlay->disk,data.bytes,data.length,[row[@"type"] intValue]),@"无法保存新提交对象；原分支未修改。");
        }
        NSString *recovery=[@"refs/repopocket/recovery/" stringByAppendingString:NSUUID.UUID.UUIDString];
        git_reference *backup=NULL;
        RPCheck(git_reference_create(&backup,repo,recovery.UTF8String,git_commit_id(ours),0,"RepoPocket history recovery"),@"无法创建恢复引用，未改写历史。"); KEEP(backup,git_reference_free);
        RPHistoryClean(repo,q,c);
        NSData *intent=[NSJSONSerialization dataWithJSONObject:@{@"operation":@"historyEdit",@"kind":kind,@"reference":@(git_reference_name(head)),@"oldHead":RPOID(git_commit_id(ours)),@"newHead":RPOID(&newID),@"preparedIndex":temporary.lastPathComponent,@"recoveryRef":recovery} options:0 error:nil];
        RPRequire([intent writeToFile:journal options:NSDataWritingAtomic error:nil],@"无法保存恢复记录，原分支未修改。"); began=YES;
        RPTestCrash(repo,q,@"beforeHistoryCheckout");
        if (revert || discard) {
            checkout.checkout_strategy &= ~GIT_CHECKOUT_DRY_RUN;
            RPCheck(git_checkout_index(repo,result,&checkout),@"历史操作签出中断，文件、恢复引用和记录已保留；请在桌面 Git 检查。");
        }
        RPExpected(@{@"head":RPOID(git_reference_target(RPHead(repo,c))),@"reference":@(git_reference_name(RPHead(repo,c)))},q);
        RPRequire(!RPIsCancelled(q[@"requestID"]),@"历史操作已取消；恢复信息已保留，请检查仓库。");
        RPCheck(git_transaction_set_target(tx,git_reference_name(head),&newID,author,"RepoPocket local history edit"),@"分支更新失败，恢复记录已保留。");
        RPCheck(git_transaction_commit(tx),@"分支更新中断，恢复记录已保留。");
        RPTestCrash(repo,q,@"afterHistoryPublish");
        RPRequire(rename(temporary.fileSystemRepresentation,[[metadata stringByAppendingPathComponent:@"index"] fileSystemRepresentation])==0,@"暂存区更新中断，恢复记录已保留。");
        RPRequire(unlink(journal.fileSystemRepresentation)==0,@"操作已完成，但恢复记录未清除，请检查仓库。"); began=NO;
        preview[@"head"]=RPOID(&newID); preview[@"commit"]=RPOID(&newID); preview[@"recoveryRef"]=recovery;
        return preview;
    } @finally {
        if (!began) unlink(temporary.fileSystemRepresentation);
        unlink(indexLock.fileSystemRepresentation);
    }
}
