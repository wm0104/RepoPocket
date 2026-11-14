# 导航、上传、Release 与外部文件流程整合验证

## 边界

- 共享工作树：`RepoPocket-ui-review-20261111`，仅本地实施。未 commit、push、dispatch，未上传真实用户文件，未安装或下载发布产物。
- 保留开始时尚未提交的 deb 元数据整合：发布日期、更新日志、多行 Description、校验与 notices 均未撤销；`DebControlEditor.swift` 本分区没有改写。
- 本分区不改 Workflow / LocalGit / LocalProject 实现、`GitHub.swift`、`project.yml` 或 `.github/workflows`。共享树中的这些差异由主 agent / 其他分区拥有，不能归为本分区修改。
- App 1.2.0、iOS 15–17 与四产物原签名配置未由本分区改动。

## 实施前 UI / 动画盘点

| 项目 | 源码依据 | 原交互与问题 | 处理 |
|---|---|---|---|
| 根 Tab | `RepoPocketApp.swift` | 提交/发布常驻 Tab 与仓库内入口重复 | 删除该 Tab；设置更新红点索引从 3 调为 2 |
| 上传表单 | `UploadView.swift` | 仓库 / Release / TrollFools 分段模式；老 Release 写入与共享发行编辑器并存 | 去除 mode 和旧 Release/Troll 流程；仅保留仓库队列 sheet |
| 队列目标、覆盖、删除 | `UploadView.swift`、`RepoQueue.swift` | HEAD 快照、目标 SHA、危险操作 confirmationDialog、单项目标重选 | 保留；队列动作改用既有真正 UIKit `NativeActionMenu` |
| deb 编辑 | `DebEditorView.swift` | 生成副本后再次点“使用”，回调不能报告采纳失败 | 上传上下文改“保存并返回”，生成校验、复制采纳成功才 dismiss；失败仍在编辑页 |
| 发行入口 | `ReleaseEntryView.swift`、`ReleaseManagementUI.swift` | 先仓库中转页，再另一个完整编辑器；新仓库可能未最终确认就创建 | 入口仅包装一个完整编辑器；仓库、新建开关、标签、分支/SHA、正文、标记、附件在同一表单 |
| 最终确认 | 上传 sheet、发行 alert、详情附件 alert | 检查错误与预览分散，失败后需重开确认 | 权限/就绪/预览/错误/重试放同一个确认页；真实写入仍需明确 confirm |
| 外部文件 | `ShareInboxStore`、原 `ShareInboxView` | 收件箱已有持久副本/选择暂存，缺少直接用途路由 | 有真实文件才显示上下文原生菜单；不新建常驻工具主页 |
| 动画、分组 | `NativeActionMenu`、`SoftGroupRows`、系统 sheet | 系统 UIMenu 展开/关闭、系统 sheet；已有折叠用无动画动态圆角 | 复用系统 presenter 和桥接；不仿菜单，不换全 App 皮肤 |

以上为源码确认，不代表已经观察过 iPhone / 模拟器运行、动画或 VoiceOver。

## 实际流程

### 1. 上传

仓库 → 代码 / 子目录 → 上传 → 添加文件 / 原有收件箱选择 → 为各队列项确认目录或显式覆盖目标 → 预览提交 → 同页检查 / 重试 → 确认全部项目。

- 根仓库概览不再额外提供上传或“新建发行版”副本入口。
- `UploadView` 不再含 mode、Troll 表单、旧 Release 下载/创建/公开服务或发布入口。外部文件也能进入该 sheet；无仓库上下文时输入仓库，再选择目录。
- 保留待删除项、逐项目标重选、同名覆盖的危险确认、默认目录继承、总量和单文件限额、HEAD / SHA 非强制提交保护。
- 确认指纹覆盖队列身份、repo/branch、路径、原 SHA、HEAD、提交说明、实际文件类型/大小及流式 SHA256。点击确认时再次核验；变更失效后留在同页，不自动写入。
- 大文件确认哈希使用 detached worker，未把整文件读入 UI 内存。

### 2. 上传中的 deb 保存

队列文件原生菜单 → 编辑包信息 → 保存并返回。

1. 沿用现有安全生成与元数据回读校验。
2. throwing 回调复制到队列自有临时目录，执行 prepareForUpload 与限额检查。
3. 按原 UUID 原位 `replaceLocal`，保留 repo、path、branch、目标 SHA、HEAD；成功后才清理旧队列副本并关闭编辑器。
4. 失败抛回编辑器：旧队列项仍在、原件不动、编辑页面不关闭。

独立编辑仍是“生成副本”与存储/分享；本地项目 `onSaveLocal` 的显式本地替换语义没有套用上传回填。

### 3. 发行

发行管理 → 新建发行版 → 一个完整表单 → 同页最终预览 / 检查 / 重试 → 明确确认。

- `ReleaseEntryView` 只是共享完整编辑器的入口，无仓库-only sheet 中转、无提前创建仓库。
- 新仓库开关显式；确认文字包含“确认创建仓库并…”。确认后成功创建的仓库记录下来，后续失败不重建、不自动删除。
- 上下文带入的文件通过 `initialFiles` 显式加入可见附件列表，只带入该次选择，不吞整个上传 queue。
- 保留 `< 2 GiB`、非空、重名拒绝、草稿、预发行 / Latest、分支及完整 SHA 选择、分页预算。
- 确认绑定正文/标签/仓库/分支及解析 HEAD/附件身份大小和内容。SHA 目标使用 commitDetail 校验，不错误调用 heads/<SHA>。
- 新发行仍先创建草稿、逐附件上传、核验已确认 receipt，全部完成才 finalize。取消与失败保留草稿和已确认附件，不自动公开或删除；续传沿用原 plan。
- 编辑发行版预检会核验原 snapshot；标记读取失败可在确认页重试。
- 原发行管理、详情分页、下载保存、编辑、删除发行版/附件（不删 git 标签）、权限及危险确认均保留。

已有发行版 → 上传附件：先经 `ReleaseAttachmentRules.copy` 取得自有副本，在独立最终确认页展示目标/文件/大小/风险，集中检查权限、原 snapshot、重名分页预算、大小及 SHA256；确认前再次核验。失败原位重试，取消不消耗原收件箱文件。

### 4. 外部文件 / 独立生成文件

- 主页只在收件箱有真实文件时显示“外部文件”上下文行。回到前台、share-in 后刷新；`onOpenURL` 的 file URL 先经现有共享收件箱协调复制。
- 每行使用 `NativeActionMenu`（真实 `UIButton.menu` / `UIMenu` / `UIAction`）：提交到仓库、作为发行附件、存储 / 分享。外部 `.deb` 额外有“编辑包信息（导出副本）”，让独立编辑可达；已生成文件菜单不重复提供该编辑入口。
- 独立生成的 deb 在其现有输出区域使用同一用途菜单；没有文件就没有用途菜单。
- 选路由前由持久收件箱 / 编辑器保有源文件；目的地另行复制。取消任何路由不删除原件。清理仅针对目的地自有副本或已有 ShareSelection 暂存。
- 未修改文档类型注册配置；直接 open-in 的系统可发现性不在本分区声明为已验证。已有分享扩展 → 收件箱是主要外部入口。

### 5. TrollFools 移除

本分区删除 `TrollMetadata.swift`、`TrollMetadataView.swift`、旧专用 `tests/MetadataTextFixture.swift`，去除页面、菜单、状态及 20 MiB 专用常量。主 agent 删除 `GitHub.swift` 中 TrollPublishResult、trollPublish、metadataSnapshot、saveMetadata、trollSize。

通用 `.dylib` / 任意文件浏览、上传、下载及远端原文件/仓库不受移除操作影响。没有加入任何远端清理。TrollStore 安装规则、安装入口及官方版本/更新查询保留。

## 测试与证据

- 新增 `Tests/test_flow_integration.py`：先在旧实现上运行得到红灯（4 项中 3 fail + 1 error）；实现后扩为 6 项，当前 5 pass、1 skip。
- 新增 `Tests/Fixtures/FlowIntegrationHarness.swift`：抽取真实生产采纳函数与 RepoQueue 指纹，使用 mock 校验和测试专有临时文件；覆盖失败保留旧项、UUID/path/SHA/HEAD 原位保留、自有复制、消失 UUID、symlink 拒绝、等长内容 / repo / branch / note 变化失效。无网络。当前宿主无 swiftc，该行为夹具尚未编译执行，需 macOS CI。
- `Tests/test_troll_metadata.py` 转为 3 个移除/共用功能保留契约，3 pass。
- `Tests/test_workspace_troll_static.py` 保留工作区删除/HEAD 等断言，并将 2 个旧专用测试转为移除与通用流式上传契约，4 pass。
- `Tests/test_deb_ui_static.py`、`Tests/test_soft_groups.py` 通过。后者仅精确归一化批准删除的专用函数、旧中转和新确认交接；其他历史 API / destructive guard 保持字节冻结，新安全链另有明确断言。deb 元数据放行未撤销。
- 下载/完成提示的安全断言已迁移到真正负责下载的 ReleaseAssetDownload / ReleaseManagementUI，而不是继续要求已移除的 UploadView 旧下载方法。
- `Tests/test_repository_upload_limits.py`：7 项、1 skip；`Tests/test_release_editor_lifecycle.py`：10 项通过。
- 原生 `StyleUITests/UploadEditorTests.swift` 改为验证保存自动返回、保留队列位置、失败就绪留在确认页；`ReleaseEditorTests.swift` 改为真实确认 sheet 和权限失败留在同页。预览 URLProtocol 增补只读 HEAD 请求，所有非 GET 仍 fail closed。它们未在当前环境运行。
- 主集成第三轮宿主回归：482 项，331 pass、151 skip、0 error、0 fail。先前唯一失败的已删除 MetadataTextFixture 存在断言已改为删除断言，并核对新 FlowIntegrationHarness、上传限额和工作流参数夹具存在。当前宿主运行器整模块排除 7 个依赖 Swift 的模块；test_troll_metadata 已参与这次完整回归。不能把 skip / 排除项算作通过。
- `Tests/test_swift_structure.py`：166 个 Swift 文件结构检查通过；这只是括号/字符串检查，不是 Swift 编译。
- `git diff --check` 通过。

## 主 agent 集成项 / 尚未验证

1. GitHub.swift：专用 Troll 删除已由主 agent完成；本分区不需要新增或放宽底层 API。
2. CI：主 agent 已登记 `Tests/test_flow_integration.py`，`Tests/test_troll_metadata.py` 保持登记且现在是移除契约；新 FlowIntegrationHarness 随前者的 native 测试执行。`test_build_workflow.py` 已适配专用旧夹具删除、新夹具存在及全量 Python 测试登记契约，13 项检查通过。仅修改本地 workflow 配置，未触发 CI。
3. 原生构建与四产物、iOS 15/16/17 模拟器/真机、UIMenu 动画、sheet 呈现顺序、动态字体 / VoiceOver / iPad 锚点尚未验证。
4. 新增文件由现有 RepoPocket/Tests 源目录规则纳入；仍需 Xcode 确认类型检查与链接。当前 Linux 无 Xcode/Swift/CryptoKit，不声称编译或真机通过。
