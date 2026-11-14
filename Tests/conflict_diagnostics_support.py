"""Instrument a disposable copy; shipping bridge and its guards stay unchanged."""
from pathlib import Path


def instrument_conflict_bridge(source, destination):
    source, destination = Path(source), Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('NativeGitBridge.m', 'NativeGitBridge.h', 'NativeGitConflict.inc',
                 'NativeGitHistory.inc', 'NativeGitStage.inc', 'NativeGitHistoryBackup.inc'):
        (destination / name).write_bytes((source / name).read_bytes())

    def inject(name, old, new):
        path = destination / name
        text = path.read_text()
        if text.count(old) != 1:
            raise AssertionError('Diagnostic anchor changed: ' + name + ': ' + old[:70])
        path.write_text(text.replace(old, new, 1))

    helper = r'''
#include <git2/sys/filter.h>
#include <ctype.h>
#include <locale.h>
static void RPFilterDiagnostic(NSDictionary *q, NSString *phase, NSDictionary *fields) {
    if (![q[@"filterDiagnostics"] boolValue]) return;
    NSMutableDictionary *row=[fields mutableCopy];
    row[@"phase"]=phase;row[@"requestID"]=q[@"requestID"] ?: @"";
    NSData *json=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
    fprintf(stderr,"RP_FILTER_DIAGNOSTIC %s\n",[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
    fflush(stderr);
}
static NSString *RPFilterDiagnosticHex(const void *bytes, size_t size) {
    const unsigned char *p=bytes;NSMutableString *hex=[NSMutableString new];
    for(size_t i=0;i<MIN(size,(size_t)128);i++) [hex appendFormat:@"%02x",p[i]];
    return hex;
}
static NSString *RPFilterDiagnosticAttr(const char *value) {
    if (GIT_ATTR_IS_TRUE(value)) return @"SET";
    if (GIT_ATTR_IS_FALSE(value)) return @"UNSET";
    if (GIT_ATTR_IS_UNSPECIFIED(value)) return @"UNSPECIFIED";
    return @(value);
}
static void RPFilterDiagnosticReview(git_repository *repo,git_blob *blob,const char *path,const git_oid *commitID,NSDictionary *q) {
    if (![q[@"filterDiagnostics"] boolValue] || strcmp(path,"代码.py") ||
        git_blob_rawsize(blob)!=15 || ((const char *)git_blob_rawcontent(blob))[14]!='\n') return;
    // These are post-call rechecks, never the original call's captured list.
    NSMutableArray *spaceBytes=[NSMutableArray new];
    for (const unsigned char *p=(const unsigned char *)path;*p;p++) {
        [spaceBytes addObject:@{@"byte":@(*p),@"isspace":@(!!isspace(*p))}];
    }
    RPFilterDiagnostic(q,@"post-filter-ctype",@{@"path":@(path),
        @"locale":@(setlocale(LC_CTYPE,NULL) ?: ""),@"bytes":spaceBytes});
    for (int pin=0;pin<2;pin++) {
        git_filter_options options=GIT_FILTER_OPTIONS_INIT;
        git_attr_options attrs=GIT_ATTR_OPTIONS_INIT;
        if (pin) {
            options.flags=GIT_FILTER_ATTRIBUTES_FROM_COMMIT;options.attr_commit_id=*commitID;
            attrs.flags=GIT_ATTR_CHECK_INCLUDE_COMMIT;attrs.attr_commit_id=*commitID;
        }
        git_filter_list *list=NULL;
        int listRC=git_filter_list_load_ext(&list,repo,blob,path,GIT_FILTER_TO_WORKTREE,&options);
        const char *names[]={"crlf","eol","text","ident","filter"};
        const char *values[5]={NULL};
        int attrRC=git_attr_get_many_ext(values,repo,&attrs,path,5,names);
        NSMutableDictionary *attributes=[NSMutableDictionary new];
        if (!attrRC) for (int i=0;i<5;i++) attributes[@(names[i])]=RPFilterDiagnosticAttr(values[i]);
        RPFilterDiagnostic(q,@"post-filter-review",@{@"path":@(path),@"pinned":@(pin),
            @"commit":RPOID(commitID),@"filterFlags":@(options.flags),@"attributeFlags":@(attrs.flags),
            @"listRC":@(listRC),@"listNull":@(list==NULL),@"length":@(git_filter_list_length(list)),
            @"containsCRLF":@(git_filter_list_contains(list,"crlf")),
            @"containsIdent":@(git_filter_list_contains(list,"ident")),
            @"attrRC":@(attrRC),@"attributes":attributes});
        git_filter_list_free(list);
    }
}
'''
    inject('NativeGitConflict.inc', 'static void RPConflictFilters(', helper + '\nstatic void RPConflictFilters(')
    inject('NativeGitConflict.inc',
           '    // Recovery fingerprints are raw worktree bytes.',
           '''    int major=0,minor=0,revision=0;git_libgit2_version(&major,&minor,&revision);
    RPFilterDiagnostic(q,@"filters-entry",@{@"repo":[NSString stringWithFormat:@"%p",repo],
        @"bare":@(git_repository_is_bare(repo)),@"workdir":@(git_repository_workdir(repo) ?: ""),
        @"commit":RPOID(commitID),@"entries":@(git_index_entrycount(index)),
        @"runtime":[NSString stringWithFormat:@"%d.%d.%d",major,minor,revision],
        @"header":@LIBGIT2_VERSION,@"optionsSize":@(sizeof(git_blob_filter_options))});
    // Recovery fingerprints are raw worktree bytes.''')
    call = 'git_blob_filter(&filtered,blob,entry->path,&options)'
    inject('NativeGitConflict.inc', '                    RPCheck(' + call + ',',
           '''                    int diagnosticRC=''' + call + ''';
                    RPFilterDiagnostic(q,@"filter-output",@{
                        @"path":@(entry->path),@"oid":RPOID(&entry->id),@"pinned":@(pinned),
                        @"flags":@(options.flags),@"rc":@(diagnosticRC),
                        @"owner":[NSString stringWithFormat:@"%p",git_blob_owner(blob)],
                        @"rawSize":@(git_blob_rawsize(blob)),@"outputSize":@(filtered.size),
                        @"rawHex":RPFilterDiagnosticHex(git_blob_rawcontent(blob),(size_t)git_blob_rawsize(blob)),
                        @"outputHex":RPFilterDiagnosticHex(filtered.ptr,filtered.size),
                        @"equal":@(filtered.size==git_blob_rawsize(blob) && (!filtered.size || memcmp(filtered.ptr,git_blob_rawcontent(blob),filtered.size)==0))});
                    RPCheck(diagnosticRC,''')
    inject('NativeGitConflict.inc',
           '    NSMutableArray *files=[NSMutableArray new];git_index_conflict_iterator *it=NULL;',
           '''    RPFilterDiagnostic(q,@"conflict-start",@{@"head":RPOID(git_reference_target(head)),@"source":RPOID(git_reference_target(source))});
    NSMutableArray *files=[NSMutableArray new];git_index_conflict_iterator *it=NULL;''')
    inject('NativeGitConflict.inc',
           '            }\n        } @finally { git_blob_free(blob); }\n    }\n}\nstatic NSDictionary *RPConflictStart(',
           '            }\n            RPFilterDiagnosticReview(repo,blob,entry->path,commitID,q);\n        } @finally { git_blob_free(blob); }\n    }\n}\nstatic NSDictionary *RPConflictStart(')
    return destination / 'NativeGitBridge.m'
