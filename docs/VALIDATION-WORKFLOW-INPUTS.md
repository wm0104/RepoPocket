# 通用工作流原生 inputs 验证

## 集成登记（主 agent）

本分区使用 **Yams 5.1.3**（Swift tools 5.4，无外部 Swift 包依赖，内含 CYaml/libyaml），不再使用受控手写 YAML 解析器。现有 TreeSitterYAMLRunestone 只提供编辑器语法分析，并非 YAML schema / 标量语义解码器；新增前仓库未发现 Yams/libyaml 依赖。主 agent 已登记以下工程依赖，并核验精确 tag commit `3036ba9d69cf1fd04d433527bc339dc0dc75433d`：

```yaml
packages:
  Yams:
    url: https://github.com/jpsim/Yams.git
    exactVersion: 5.1.3
# RepoPocket target dependencies 增加：
      - package: Yams
```

保留最低 iOS 15、App 1.2.0、签名及四包配置。主 agent 已补 `Licenses/WorkflowInputs/Yams-MIT.txt`、`libyaml-MIT.txt` 以及 bundle / THIRD_PARTY_NOTICES 登记；本分区没有修改他人已编辑的工程/许可证文件。

测试入口新增 `python3 Tests/test_workflow_inputs.py`。既有 `python3 Tests/test_workflow_dispatch.py` 保留，已升级为同一生产 schema/transport 的 URLProtocol 验证。UI 测试新增 `WorkflowInputsTests/testNativeInputsDefaultsValidationAndMenuSelectionWithoutDispatch`；现有 `StyleBoundaryTests/testWorkflowFilterCornersSurviveDispatchAndRefresh` 仅增加等待 schema 真正 ready 的断言。主集成已将 Python 测试登记在 `build.yml`，并把新增 UI 用例加入既有 `workflow-selection` 测试范围；仅本地登记，未运行 CI。

Swift 原生测试通过 `Tests/workflow_inputs_support.py` 在外置缓存创建并清理 SwiftPM fixture，固定同一 Yams 版本。当前 iSH 默认位于 `/var/minis/mounts/minis缓存目录/RepoPocket-workflow-inputs-tests`，支持 `REPOPOCKET_TEST_CACHE` 覆盖；没有该挂载的 macOS / CI 默认使用 TMPDIR 下专用目录。package、scratch/build、源码 checkout cache 均显式外置，不会在工作树产生 .build、Package.resolved 或日志。SwiftPM 首次运行需要取得该版本源码，不会运行 GitHub Actions、上传、下载产物或安装 App。

## 行为与边界

- Actions 与推送后运行入口继续复用 `WorkflowDispatchView`；工作流、已有分支、choice、environment 使用现有 NativeActionMenu 的真实 UIMenu 构造。选择适配层复用其 Coordinator，并用真正的 `UIAction.state` 表示单选；不改共享菜单实现。boolean 用 Toggle，string/number 用 TextField，不嵌网页。低频分页加载折叠到“列表选项 → 分页加载”。
- Yams `compose` 解析完整合法 YAML；只遍历根键、`on`、`workflow_dispatch` 和 `inputs`。jobs 的 flow mapping、matrix、shell 块、表达式及合法 anchors 不参与 schema 校验，不应阻止参数表单。读取 literal `on` 键，避免 YAML 1.1 把它隐式转换为 bool。
- 支持 string / choice / boolean / number / environment；未写 type 的历史 inputs 按 string。显示描述、required、default，按声明顺序呈现。只发送本 schema 声明的参数，不注入 run_title；声明 run_title 才会出现该输入。
- 区分 workflow_dispatch 无 inputs 与未声明 workflow_dispatch。后者、未知类型/字段、自定义 schema tag、重复相关键、schema merge key、schema 动态表达式、非标量 defaults、非法 choice / number 一律阻止启动并说明原因；不会尝试猜测发送。
- 支持 YAML 引号、折叠/字面块、flow 配置、已解析的 aliases；不是正则 YAML。Yams singleRoot 拒绝多文档。根映射的重复键与 merge key 也阻止启动；不会检查 jobs 内部的 schema 语义是否合法，最终由 GitHub 校验。
- GitHub 文档（2026-11-12 读取）列出上述五种类型、最多 25 个顶层 inputs、65,535 字符 payload。本实现保守采用 65,535 UTF-8 JSON 字节上限；工作流文件读取上限 512 KiB，number 为有限 JSON 数字（不接受 NaN/Infinity/hex/地区化逗号）。
- environment 从同仓库 environments API 完整分页读取；无法完整读取就不提供可发送 schema。只能选已读取的 environment，不自动创建 environment。可选空值省略，显式默认值会显示并发送；boolean 未设 default 以 false 呈现。
- 切工作流/ref 立即取消旧 schema task，清空参数、确认和 definition；请求以 epoch、账号 accountID + generation、repo 绑定，旧响应不能覆盖新状态。schema 加载中/失败/未读/校验失败不允许确认。重试仅重读 schema，不会重发 POST。
- 确认快照包含实际 repo/ref、工作流文件、完整 JSON inputs。提交前核对原输入快照与 epoch；唯一 dispatchWorkflow 入口重新校验仓库写权限、active workflow、路径、已有分支、源码 SHA、参数及环境列表，再使用既有账号绑定 URLSession + OfficialUpdateRedirectPolicy 发送。没有第二套凭证或网络 session。
- 204 才视为接受；confirmation 在首次 await 前消费，attempted 锁不回退。不确定结果不自动重发，沿用原有权限说明、关闭约束和明确刷新提示。预检后远端仍可能变化，这是 GitHub API 无法消除的竞态，最终由服务端校验。

## 原有 UI / 动画盘点

| 项目 | 原实现与处理 |
|---|---|
| 原生表单/分组 | SwiftUI List + SoftGroupRows；保留动态行圆角及间距，动态插入/移除 schema 行。 |
| 选择 | 原 Picker 改为现有 NativeActionMenu 的 UIMenu；菜单展开、关闭均由系统执行，没有自绘浮层。 |
| 确认/关闭 | 原 confirmationDialog + dismiss + interactiveDismissDisabled(busy) 保留；只把默认文案替换为真实 inputs。 |
| 运行详情/日志动画 | 不改 WorkflowRunView 的 withoutAnimation、任务/步骤展开及系统页面动画。 |

## 验证记录

待最终原生编译补验；本机记录如下（未触发任何真实 run）：

1. 旧 `test_workflow_dispatch` 在替换 Picker/固定 run_title 后先出现预期静态回归红灯；随后更新为 UIMenu/schema/真实 inputs 断言，保留权限、确认消费、防重复、204、不确定结果不重发和账号隔离检查。
2. 工作流专用回归：21 项，17 passed / 4 skipped（schema fixture、dispatch URLProtocol、selection fixture、rerun fixture 因缺少 Swift/macOS 未执行）。
3. iOS15 / NativeActionMenu / SoftGroupRows / Swift 结构相关回归组合：30 项，27 passed / 3 skipped；同时通过组件脚本的动态分组矩阵与历史业务保护检查。这是静态/脚本验证，不是原生 UI 编译或像素验收。
4. API 冻结保护 `test_browser_no_releases`：1 passed / 1 skipped；历史基线已在本地，不执行 git fetch，无需为本分区放宽冻结块。
5. 独立 PyYAML BaseLoader 交叉核查实际 `.github/workflows/build.yml`（5 inputs）、受控 sync-upstream 夹具（3 inputs）、UI 预览 YAML（5 inputs）语法与形状通过；不等同于生产 Yams/Swift 执行。提供的工作树不存在真实 `sync-upstream.yml`，因此只添加标明“controlled”的专用同步夹具，未冒称验证该真实文件。
6. `git diff --check` 针对本分区既有修改文件通过。新增 Swift 文件已做人工 API/生命周期检查；当前设备无 swift/swiftc/Xcode，**生产 schema/URLProtocol 的原生红绿、App 原生编译、iOS15～17 模拟器与真机交互均未执行**，不可据上述静态结果宣称通过。

首次合并相关入口共 **42 项：36 passed / 6 skipped**。并行加入冲突编辑页后，曾因顶层条件 ToolbarContent 出现 1 项真实 iOS15 静态回归；冲突分区已将条件置于 ToolbarItem 内，主集成重跑兼容套件 **13 项通过**。工作流专用最终复跑仍为 **21 项：17 passed / 4 skipped**。另有一次把 `.autocorrectionDisabled()` 误判为 iOS16-only 的审查结论已根据 Apple 文档及对应 SDK 接口纠正，该 API iOS13 起可用，不作为真实兼容缺陷计数。所有执行均为本地，无真实网络 mutation。

原生 fixture 覆盖：五种类型、默认值、声明顺序、必填/类型/选项/environment校验、有限 JSON 数字、literal `on`、无 inputs vs 未声明 dispatch、未知类型/tag/重复键/多文档、65,535 byte 上限、真实 build.yml 及复杂 flow/shell/matrix/aliases。URLProtocol 追加 schema读失败禁发、真实 ref query、五类实际 payload、未声明 run_title 禁发、源码 SHA 变化禁发、切 ref 取消旧响应等；既有权限和未知结果安全断言保留。

日志、下载的公开参考源码和本轮生成脚本均已迁到外置缓存 `/var/minis/mounts/minis缓存目录/RepoPocket-workflow-inputs-validation-20261112/`，没有占用 `/var/minis/workspace` 的遗留本分区文件。测试输出不入仓库。
