// Fetch into a fresh bare repository: no checkout, saved credential or remote write.
static NSDictionary *RPHistoryBackup(NSMutableDictionary *q, RPGitResources *c) {
    NSString *remoteURL=RPString(q,@"remote"), *branch=RPString(q,@"branch");
    RPRequire(RPAllowedRemote(remoteURL),@"原历史备份仅支持GitHub HTTPS仓库。"); RPBranch(branch);
    NSString *requested=RPString(q,@"destination"), *parent=RPReal(requested.stringByDeletingLastPathComponent);
    NSString *destination=[parent stringByAppendingPathComponent:requested.lastPathComponent];
    struct stat existing;
    RPRequire(requested.isAbsolutePath && requested.lastPathComponent.length &&
              lstat(destination.fileSystemRepresentation,&existing)!=0 && errno==ENOENT,
              @"备份目标已存在或不安全，未覆盖任何原文件。");
    git_oid expectedHead,expectedTree;
    RPRequire(RPString(q,@"expectedHead").length==40 && RPString(q,@"expectedTree").length==40,
              @"原历史备份快照无效。");
    RPCheck(git_oid_fromstr(&expectedHead,[q[@"expectedHead"] UTF8String]),@"备份HEAD无效。");
    RPCheck(git_oid_fromstr(&expectedTree,[q[@"expectedTree"] UTF8String]),@"备份代码树无效。");
    NSInteger expectedCount=[q[@"expectedCount"] integerValue];
    RPRequire(expectedCount>0 && expectedCount<=5000,@"备份历史数量无效。");
    git_repository *repo=NULL;
    RPCheck(git_repository_init(&repo,destination.fileSystemRepresentation,1),@"无法创建本机原历史备份。"); KEEP(repo,git_repository_free);
    q[@"credentialRemote"]=remoteURL; q[@"credentialUsed"]=@NO; q[@"historyBackup"]=@YES;
    git_remote *remote=NULL;
    RPCheck(git_remote_create_anonymous(&remote,repo,remoteURL.UTF8String),@"无法读取原历史。"); KEEP(remote,git_remote_free);
    git_fetch_options options=GIT_FETCH_OPTIONS_INIT;
    options.callbacks=RPCallbacks(q); options.follow_redirects=GIT_REMOTE_REDIRECT_NONE;
    options.download_tags=GIT_REMOTE_DOWNLOAD_TAGS_NONE;
    NSString *refspec=[NSString stringWithFormat:@"refs/heads/%@:refs/heads/original",branch];
    char *spec=(char *)refspec.UTF8String; git_strarray specs={&spec,1};
    int rc=git_remote_fetch(remote,&specs,&options,"RepoPocket original history backup");
    RPRequire(![q[@"backupBudgetExceeded"] boolValue],@"原历史备份超过256 MiB或对象数量限制，未整理远端历史。");
    RPCheck(rc,@"原历史备份未完成，请检查网络、空间和读取权限；远端历史未改动。");
    RPRequire(!RPIsCancelled(q[@"requestID"]) && !git_repository_is_shallow(repo),@"原历史备份已取消或不完整，未改动远端。");
    git_reference *reference=NULL;
    RPCheck(git_reference_lookup(&reference,repo,"refs/heads/original"),@"备份分支缺失。"); KEEP(reference,git_reference_free);
    RPRequire(git_reference_target(reference) && git_oid_equal(git_reference_target(reference),&expectedHead),@"备份期间远端HEAD已变化，请重新预览。");
    git_commit *commit=NULL;
    RPCheck(git_commit_lookup(&commit,repo,&expectedHead),@"无法核实备份提交。"); KEEP(commit,git_commit_free);
    RPRequire(git_oid_equal(git_commit_tree_id(commit),&expectedTree),@"备份代码树与预览不一致，未改动远端。");
    git_revwalk *walk=NULL;
    RPCheck(git_revwalk_new(&walk,repo),@"无法核实备份祖先。"); KEEP(walk,git_revwalk_free);
    RPCheck(git_revwalk_push(walk,&expectedHead),@"备份HEAD无法遍历。");
    NSInteger count=0; git_oid oid;
    while ((rc=git_revwalk_next(&oid,walk))==0) {
        RPRequire(!RPIsCancelled(q[@"requestID"]) && ++count<=5000,@"备份已取消或历史超出5000条，未改动远端。");
    }
    RPRequire(rc==GIT_ITEROVER && count==expectedCount,@"备份祖先不完整或数量与预览不一致，未改动远端。");
    RPCheck(git_repository_set_head(repo,"refs/heads/original"),@"无法记录备份分支。");
    return @{@"head":RPOID(&expectedHead),@"tree":RPOID(&expectedTree),@"commits":@(count)};
}
