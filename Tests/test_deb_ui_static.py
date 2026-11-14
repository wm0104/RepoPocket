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
assert 'AppShareLink(item: output' in d
assert 'TargetPickerView(api: api' in u and 'invalidateTarget()' in u
release = (r/'ReleaseManagementUI.swift').read_text()
assert 'saveManagedRelease' in release and 'uploadManagedAsset' in release
assert 'createRelease' not in u and 'uploadSelected' not in u
assert 'DebControlEditor.fields(at:' in d
assert 'enum DebControlReader' not in d
assert '.onDisappear' not in d
assert 'dir.appendingPathComponent(source.lastPathComponent)' in d
assert 'title: "编辑包信息"' in u
assert 'item.local?.pathExtension.lowercased() == "deb"' in u
assert 'queue[index].replaceLocal(copy' in u
adoption = u.split('    private func adoptGeneratedDeb(', 1)[1].split('    private func queuedUploadBytes(', 1)[0]
assert 'alertText =' not in adoption, 'Adopting an edited deb must not present an alert while its editor sheet is dismissing'
assert '.sheet(item: $editingItem)' in u
assert 'try adoptGeneratedDeb(generated, replacing: item.id)' in u
assert 'try onUseForUpload(target)' in d
assert '保存并返回' in d
assert '.sheet(isPresented: $confirmCommit)' in u
assert 'RepoQueue.readiness(queue' in u
assert 'submitAfterDismiss' not in u
assert 'checkedFingerprint() == authorized' in u
assert 'reviewError = error.localizedDescription' in u
assert '.confirmationDialog("一次提交' not in u
assert 'catch { alertText = error.localizedDescription }' in u
assert 'source.subdata(in: originalData.start..<originalData.end) == result.subdata(in: checkedData.start..<checkedData.end)' in e
assert 'Data(contentsOf: file' not in d
assert 'X-WM0104-Release-Date' in e and 'X-WM0104-Changelog' in e
assert 'DebControlEditor.releaseInformation(fields: fields)' in d
assert 'TextEditor(text: $changelog)' in d
assert 'TextField("发布日期（YYYY-MM-DD）", text: $releaseDate).textInputAutocapitalization(.never).disableAutocorrection(true)' in d
assert 'releaseDate: releaseDate, changelog: changelog' in d
assert 'verified[$0.key] == ($0.value.isEmpty ? nil : $0.value)' in d
print('deb UI integration static checks passed')
