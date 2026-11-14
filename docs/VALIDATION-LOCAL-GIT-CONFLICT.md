# 本地 merge 冲突闭环验证（2026-11-12）

## 后续固定依赖解析修复（2026-11-12）

- 原生诊断运行 `43197164818 / e540c83` 实际执行 25 项冲突测试，24 通过、1 失败；中文属性模式未触发应有的 checkout 转换。Apple 线程实际观测 `isspace(0xA0)=1`，ASCII 模式对照正常转换并拒绝。
- 保持 libgit2 固定 revision、原始归档 SHA 和版本；构建时仅对 `attr_file.c` 的 7 个空白调用应用确定性 ASCII 六空白修复，不修改全局 locale 或生产 Bridge 的逐字节保护。原始文件与补丁后文件均严格核对 SHA，未知源码拒绝；重复调用不重写已补丁文件。
- `build.yml`、`local-git-check.yml`、`ui-check.yml` 的原生库缓存键包含补丁工具；三个 SDK 共用同一构建接入，日志输出实际补丁后源码 SHA。
- 保留原中文反例及 ASCII 对照，新增含 UTF-8 `0x85`、普通中文、真实 U+00A0 路径的过滤拒绝和共享 `.gitignore` 解析回归，覆盖 TAB、CRLF、相邻规则、末行无 LF 与反选；未削弱无写入断言。
- Windows 本机针对性回归 11 个脚本共 142 项：59 通过、83 跳过、0 失败；其中补丁工具 6 项为 5 通过、1 项缺 C 编译器跳过，冲突 29 项为 6 通过、23 跳过。已真实校验固定官方归档/源码摘要、补丁输出、幂等与未知源码拒绝；Bash 语法和 `git diff --check` 通过。
- 本节是本机检查快照，不能替代后续 Apple 原生反例红绿、iOS 编译、四包或真机结果；以下为此前功能实现阶段记录。

## 交付状态

已接通生产源码的有界冲突闭环；**尚未完成 Apple 原生编译、生产桥接行为执行或真机验收**。当前环境是 Linux，已有 clang/libgit2 1.8.4，但没有 Swift 编译器、macOS Foundation 或 Xcode。未下载、安装或触发 CI；没有 commit/push 共享项目、没有写真实用户仓库。

工作树包含其他 agent 的既有并行变更，未回退或归并它们。没有修改 NativeGitHistory.inc、独立 stage 文件、Upload/Release/Workflow/RepoPocketApp、签名或版本配置。project.yml 保持 App 1.2.0；四包路径未动。

## 生产实现

新增：
- Vendor/NativeGit/NativeGitConflict.inc
- RepoPocket/LocalGitConflictModels.swift
- RepoPocket/LocalGitConflictView.swift
- RepoPocket/LocalGitConflictEditor.swift
- Tests/test_local_git_conflict.py
- Tests/Fixtures/LocalGitConflictBlocksFixture.swift

最小接线：NativeGitBridge.m、LocalGitEngine.swift、LocalGitModels.swift、LocalGitMerge.swift、LocalProjectView.swift。

### 状态与数据安全

- 分支合并继续使用既有 overlay ODB 预览。冲突预览不会写 index、工作文件或分支；用户明确确认后调用 mergeStart。
- 分叉 pull 在既有受控 fetch 后验证当前分支的安全 origin upstream，并进入同一普通 merge 路径。无冲突分叉合并仍要求用户确认的作者；缺少身份拒绝生成提交，不猜测邮箱。pull 确认文案披露合并提交与冲突暂停，不自动推送。
- 开始前要求 clean worktree/index、无其他操作，复用 pinned HEAD/ref/source、目录 identity、协调写权限、串行队列、账号 generation、取消、owned locks 和图/树预算。
- 持久保存真实 Git 冲突 stages 1/2/3、MERGE_HEAD、MERGE_MSG、ORIG_HEAD；应用日志为 .git/repopocket-merge.json，含 session、oldHead/sourceSHA、方法、阶段、冲突原始 stages、worktree 指纹、index 前/后指纹及 prepared index 路径。
- 原 index 原始字节和既有 ORIG_HEAD 字节有快照。当前与传入提交分别由 refs/repopocket/recovery/<UUID> 及其 -incoming 引用保留；不依赖来源分支之后仍存在。
- 阶段为 resolving / continuing / aborting。预备 index 和日志先落盘，再原子安装 index；上一步或下一步已知 index 指纹可识别断点，但未知 index 内容一律拒绝覆盖。重进 status 优先呈现 mergePending，不引导普通暂存/提交。
- 解决期间只写对象与 index，不写工作文件。逐文件可选择当前/传入完整内容（该方不存在即删除）、明确删除，或保存 UTF-8 编辑结果。手动结果限制 2 MiB，拒绝 NUL、二进制转换及残留冲突标记。
- 全部解决后再次检查整个 index 无 conflict、结果树预算、当前分支与指纹、外部工作文件变化和安全 dry-run checkout。明确继续才签出并发布普通双亲或 squash 单亲本地提交；不 push、不触发工作流。
- 中止恢复原始 index 字节与此前 ORIG_HEAD。若继续阶段已开始签出，则仅在每个受影响路径仍匹配“旧快照或本会话结果”时，用 SAFE checkout 恢复原树。不使用 FORCE、hard reset、clean 或删除无关 untracked/ignored 文件。
- 签出后取消/杀进程仍保留日志；HEAD 尚未发布可再次继续或中止，HEAD 已发布只能继续完成收尾，不暗中回滚已发布本地提交。未知外部修改、未知锁或损坏记录保守拒绝并保留证据。

### 两处独立 review P2 修复

1. RPConflictMutate 获取 HEAD/ref、ORIG_HEAD 和 index 锁后，重新 RPHead，再校验 expectedHead/ref、会话 old/newHead 和实际锁定的分支名；之后使用锁后引用。相同 tree 的新 commit 或同 tree 切分支不再绕过工作文件指纹检查。新增可释放的测试屏障覆盖初次检查至加锁前的竞态。
2. RPClearStaleOwnedLocks 在没有普通事务日志时，可严格使用合并日志的发布证据：session UUID、version、continuing 阶段、reference、lease.head==session.oldHead、有效 old/new OID、当前 expectedHead 属于 old/new 都必须匹配。仅允许该 reference 对应的 .lock 内容等于 session.newHead 加换行；device/inode/birth、死进程与 owned marker 等原校验全部保留。HEAD.lock、ORIG_HEAD.lock 或未知内容不因此放宽。

发布前中断 fixture 在 RP_GIT_TESTING 中保留 leased inode，将目标 ref.lock 写为 newOID，暂停于 rename 前；它准确构造所需持久窗口，不声称在 libgit2 内部增加了生产回调。

## UI

保留系统导航、确认弹窗、SoftGroupRows 和既有预览 diff。手机默认结果视图，用 segmented Picker 切换结果/当前/传入，不强制三栏。文本复用 SourceCodeEditor；逐块采用当前/传入/双方使用 NativeActionMenu 的真实 UIMenu/UIAction，手动编辑直接编辑结果。二进制同时展示当前、传入与已选结果 OID/删除状态。文件列表显示已解决/总数，继续与中止都有明确确认。

iOS 15 工具栏条件已移到 ToolbarItem 内容内部，未使用仅 iOS 16 的顶层 conditional ToolbarContentBuilder。没有新增自绘菜单、卡片堆叠或菜单动画。

## 有意保守拒绝的范围

- 复用现有完整历史 2000 commits、单文件 2 MiB、每棵树 32 MiB、10000 entries、单一 merge base、非 shallow、非 symlink/submodule 的合并边界；冲突最多 200 文件，前后路径并集最多 10000，日志最多 8 MiB。
- 不开启 rename 相似度搜索。常见“原路径修改、传入改名/删除”按原路径删除/修改冲突与独立新增目标路径展示，可明确保留或删除原路径；跨路径 stages、目录/文件碰撞等不能安全逐文件解决的情形在开始前有理由拒绝，不猜测 rename 意图。
- 恢复指纹基于原始工作树字节。若 CRLF、ident 或其他 checkout 过滤会改变双方或结果文件字节，则在签出前明确拒绝；不能声称此类过滤仓库已支持完整中止。开始与继续分别验证默认属性和 pinned commit 属性。
- 外部改变工作文件、index、HEAD/ref、ORIG_HEAD、MERGE_HEAD/MERGE_MSG 或替换 owned 锁时，不自动修复或删除未知数据；必须先保留并处理外部变化。
- 没有 rebase/cherry-pick、shell git 生产 fallback、自动推送或远端冲突解决。

## 实际执行的验证

全部 Python 字节码、编译产物、日志及临时仓库位于项目树外；未执行任何包安装。

1. `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_local_git_conflict.py' -v`：21 项，4 项源码契约通过、17 项跳过（16 项生产 ObjC 原生行为 + 1 项真实 Swift fixture，缺 Apple/Swift 工具链）。**不是 21 项行为通过。**
2. `... -p 'test_local_git*.py'`：120 项，30 项通过、90 项跳过；没有失败。包含并行既有文件的当前共享树结果。
3. `... -p 'test_ios15_compatibility.py'`：修复后首次 12 项通过；最后共享树当前套件 13 项全部通过（套件由其他 agent 并行增补，本分区未弱化测试）。
4. `PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_swift_structure.py`：172 个 Swift 源码括号/字符串结构检查通过，**不是 Swift 类型检查或编译**。使用 unittest 导入该脚本只会运行 0 项，故已直接执行其真实入口。
5. 既有 branch_merge_entry：3 项通过；native_action_menu：6 项通过、1 项因缺 Swift 跳过。
6. `git diff --check` 指定上述共享修改文件：通过。
7. 用系统现有 clang/libgit2 运行项目树外的 C 机制探针，临时合成仓库自动删除：确认三阶段冲突 index 复制后仍保持 3 entries/conflicts，明确解决后的 SAFE+DONT_UPDATE_INDEX+baseline 签出成功，再以结果树为 baseline 的非强制恢复成功。**这只是 libgit2 机制验证，不是 shipping ObjC bridge 或 Swift UI 执行。**

新增待原生运行行为覆盖：text 双亲提交/重进、逐字节 abort 与新增/忽略文件保留、binary 选择与拒绝手动转码、rename-delete 差异、分叉 pull 自建 file:// bare origin 且不自动 push、未解决标记、旧指纹、外部 index/worktree 修改、初始 index 安装中断、签出中断、已发布中断、同 tree 新提交/切分支竞态、发布前 OID 锁可继续/可中止、未知 OID 锁拒绝删除。

## 后续集成边界

本分区共享 Bridge.m / LocalGitEngine / LocalProjectView 可由主 agent 接独立 stage 功能。stageStatus/stageDiff/stage/unstage/commitStaged 由主 agent 登记；写协调仅对 stage/unstage/commitStaged 增加。工作区只加一个“暂存与提交”入口，mergePending 时必须优先进入冲突页面并禁用普通 stage，不能放宽 RPWritable。本分区未修改独立 stage 文件或 CI 登记。
