from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import subprocess, tempfile
source = Path(REPO_ROOT, 'RepoPocket/DesktopModels.swift').read_text() + r'''
for name in ["main", "feature/mobile", "中文分支", "release-0.7"] { precondition(DesktopRules.validBranch(name)) }
for name in ["", "HEAD", "@", "a..b", "a b", "a\\b", "/a", "a/", ".a", "a.lock", "a/.b", "a//b", "a@{b", "a?b", "a:", "a[", "a*", "a~", "a^", "-bad", "a\n"] { precondition(!DesktopRules.validBranch(name)) }
let shanghai = TimeZone(identifier:"Asia/Shanghai")!
precondition(CommitDatePresentation.local("2026-10-15T14:41:46Z",timeZone:shanghai) == "2026-10-15 下午 10:41")
precondition(CommitDatePresentation.local("2026-10-15T14:41:46.123Z",timeZone:shanghai) == "2026-10-15 下午 10:41")
precondition(CommitDatePresentation.local("2026-10-15T22:41:46+08:00",timeZone:TimeZone(secondsFromGMT:0)!) == "2026-10-15 下午 2:41")
precondition(CommitDatePresentation.local("2026-10-15T23:41:46Z",timeZone:shanghai) == "2026-10-16 上午 7:41")
let newYork = TimeZone(identifier:"America/New_York")!
precondition(CommitDatePresentation.local("2026-07-15T14:41:46Z",timeZone:newYork) == "2026-07-15 上午 10:41")
precondition(CommitDatePresentation.local("2026-01-15T14:41:46Z",timeZone:newYork) == "2026-01-15 上午 9:41")
precondition(CommitDatePresentation.local("invalid",timeZone:shanghai) == "时间未知")
let raw = #"{"sha":"abc","commit":{"message":"Title\n\nBody","author":{"name":"Test","date":"2026-10-10T00:00:00Z"}},"stats":{"total":3,"additions":2,"deletions":1},"files":[{"filename":"目录/new.txt","previous_filename":"old.txt","status":"renamed","additions":2,"deletions":1,"patch":"@@ -1 +1 @@\n-old\n+new"},{"filename":"file.deb","status":"modified","additions":0,"deletions":0}]}"#
let commit = try JSONDecoder().decode(DesktopCommit.self, from: Data(raw.utf8))
precondition(commit.commit.message.contains("Body") && commit.files!.count == 2)
precondition(commit.files![0].previous_filename == "old.txt" && commit.files![0].preview.contains("+new"))
precondition(commit.files![1].preview.contains("二进制"))
let large = DesktopCommit.File(filename:"large",previous_filename:nil,status:"modified",additions:1,deletions:0,patch:String(repeating:"a",count:100001))
precondition(large.preview.contains("截断"))
let branches = try JSONDecoder().decode([DesktopBranch].self, from: Data(#"[{"name":"feature/mobile"}]"#.utf8))
precondition(branches[0].id == "feature/mobile")
print("PASS Desktop models: ref validation, mocked commit/files/rename/binary/truncated diff and branches")
'''
with tempfile.TemporaryDirectory() as d:
    p=Path(d)/'main.swift'; p.write_text(source)
    subprocess.run(['swiftc',str(p),'-o',d+'/tests'],check=True)
    subprocess.run([d+'/tests'],check=True)
g=Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
a=Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
v=Path(REPO_ROOT, 'RepoPocket/DesktopViews.swift').read_text()
assert v.count('@ScaledMetric(relativeTo: .body)') == 2
assert 'messageExpanded ? nil : 4' in v and 'messageExpanded.toggle()' in v
assert '.font(.system(size: messageSize, weight: .medium))' in v
assert '.font(.system(size: messageSize, weight: .regular))' in v
for removed in ['MagnificationGesture', 'textScale', 'detailScale', '重置字号']:
    assert removed not in v
assert 'let sha: String' in v and '@State private var detail: DesktopCommit?' in v
assert '@State private var files: [DesktopCommit.File] = []' in v
assert '.textSelection(.enabled)' in v and '收起说明' in v and '展开完整说明' in v
print('PASS commit text contracts: Dynamic Type, expansion, preserved detail state, no ineffective pinch or reset')
assert '"/commits/" + Self.component(sha)' in g and '.init(name: "sha", value: branch)' in g
create=g[g.index('    func createBranch'):g.index('    func fetchWorkspace')]
assert '== expectedHead' in create and 'method: "POST"' in create and '"refs/heads/" + name' in create and 'PATCH' not in create
assert 'remote: (repo, entry, activeBranch)' in a and 'initialBranch: activeBranch' in a
assert 'HistoryView(api:' in a and 'BranchPickerView(api:' in a
assert 'page < 30' in v and 'page += 1' in v and 'confirm = true' in v
print('PASS Desktop API and UI contracts: pagination, encoded SHA, selected branch, stale head, no forced overwrite')
