# 本地 Git 内核路线

RepoPocket 的本地 Git 功能使用开源 `libgit2`，不依赖付费服务。

第一阶段建立 `GitCore` 模块边界：导入并验证本地 `.git` 仓库，保存安全书签，所有 UI 通过 `GitCore` 调用。下一阶段接入 libgit2，实现状态、暂存、提交和历史；之后实现克隆、拉取、推送、分支、合并和冲突解决。

GitHub API 与本地 Git 内核保持分离。Token 和 SSH 私钥继续存储在钥匙串中。
