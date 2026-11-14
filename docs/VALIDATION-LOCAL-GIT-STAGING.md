# 独立暂存与已暂存提交验证

## 实现与正式集成

- `NativeGitStage.inc` 已由生产 `NativeGitBridge.m` include；stageStatus、stageDiff、stage、unstage、commitStaged 均在真实调度注册并使用原目录扫描预算。
- stage、unstage、commitStaged 纳入 `LocalGitEngine` 既有串行写协调，不新增写队列。
- 本地项目操作区域仅有一个“暂存与提交”入口。有未完成合并时优先冲突页面，普通暂存入口禁用；没有全局放宽 `RPWritable`。
- 无暂存时原选中文件提交保持可用；存在暂存时提示进入同一个面板，不再要求去其他工具。

## 语义与保护

- 暂存只处理显式勾选且指纹核验通过的工作文件；保留其他暂存项。取消暂存只还原 HEAD 中对应 index 条目，新暂存项从 index 删除；工作文件不变。
- 已暂存差异是 HEAD → index，未暂存差异是 index → 工作区。同一路径可以同时出现在两侧。
- 提交使用全部已确认 index 内容，不重新 add 工作区文件，因此不带入之后的未暂存改动，不自动推送。提交说明与作者沿用既有状态。
- HEAD/ref、全 index 原始哈希、各侧文件指纹均需核对；拒绝冲突、mergePending、中断状态、不安全路径、符号链接、子模块、特殊 index flags、LFS 或自定义 filter。
- 使用独占 index.lock、持有 descriptor 的 inode/device 所有权检查、prepared index、fsync 与 atomic rename。不会删除其他工具的锁，不 reset、clean 或改写工作文件。
- staged commit 复用既有 commit journal / recover 协议。原子发布后取消只提示重新核验，不冒称撤销已经完成的写入。
- 前台恢复仅在页面有效且空闲时重读 stageStatus；后台取消请求并使旧快照和确认失效，不因回到前台执行写入。

## 实际验证

- 正式接线前，生产 include/dispatch 契约先失败；接线后通过。测试不再为临时 translation unit 补造生产调度，直接复制真实生产 bridge 执行。
- 暂存套件：14 项，3 项静态契约通过、11 项生产原生 FFI 因缺 macOS 工具链跳过。
- FFI 用例覆盖选定路径、其他暂存项保留、删除/新增取消暂存、工作区后续更改不进提交、双向差异、陈旧 HEAD/index/文件指纹、外部锁、取消、限制类型及发布中断后的恢复。
- 当前 iSH 的日志与缓存置于外置 `repopocket-flow-integration`；设置 PYTHONDONTWRITEBYTECODE=1，未遗留本轮内部 workspace 暂存缓存。macOS fixture 使用宿主临时目录，Git CLI 仅用于创建与断言一次性 fixture，不替代生产实现。
- 原生接口使用项目既有组件与系统动画。邮箱 `.autocorrectionDisabled()` 经 Apple 文档和 iOS 18.5 SwiftUI 接口核对为 iOS13 起可用的 alwaysEmitIntoClient 包装，不是 iOS16-only API。

## 限制与未验证

沿用现有 RPHead，不接管空仓库、detached HEAD、worktree；不实现 hunk staging、提交部分暂存路径或改名相似度推断。崩溃可能留下未发布的 UUID prepared 文件，不猜测清理。

未进行 Apple 原生编译、macOS FFI 执行、iOS15～17 模拟器或真机验证。静态检查通过不代表生产行为通过。未 commit、push、触发 CI 或操作真实用户仓库。
