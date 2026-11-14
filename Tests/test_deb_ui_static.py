from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
r=Path(REPO_ROOT, 'RepoPocket')
a=(r/'RepoPocketApp.swift').read_text()
u=(r/'UploadView.swift').read_text()
d=(r/'DebEditorView.swift').read_text()
e=(r/'DebControlEditor.swift').read_text()
assert 'Menu { Button("编辑包信息")' in a
assert 'api.downloadFile(remote.repo, entry: entry, branch: head)' in d
assert 'api.saveRemoteDeb(' in d
assert 'Button("提交回原文件")' in d
assert 'Section("deb 工具")' not in u
assert 'allowedContentTypes: [UTType(filenameExtension: "deb") ?? .data, .data]' in d
assert 'startAccessingSecurityScopedResource' in d and 'copyItem(at: url, to: copy)' in d
assert 'DebControlEditor.edit(input: source, output: target, changes: changes)' in d
assert 'ShareLink(item: output' in d
assert 'TargetPickerView(api: api' in u and 'invalidateTarget()' in u
assert 'createRelease' in u and 'uploadSelected' in u
assert 'DebControlEditor.fields(at:' in d
assert 'enum DebControlReader' not in d
assert '.onDisappear' not in d
assert 'dir.appendingPathComponent(source.lastPathComponent)' in d
assert 'Button("编辑包信息")' in u
assert 'item.local?.pathExtension.lowercased() == "deb"' in u
assert 'queue[index].replaceLocal(copy' in u
assert '.sheet(isPresented: $confirmCommit, onDismiss:' in u
assert 'RepoQueue.readiness(queue' in u
assert 'submitAfterDismiss = true; confirmCommit = false' in u
assert '.confirmationDialog("一次提交' not in u
assert 'catch { alertText = error.localizedDescription }' in u
assert 'source.subdata(in: originalData.start..<originalData.end) == result.subdata(in: checkedData.start..<checkedData.end)' in e
assert 'Data(contentsOf: file' not in d
print('deb UI integration static checks passed')
