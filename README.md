# RepoPocket

![累计下载次数](https://img.shields.io/github/downloads/wm0104/RepoPocket/total?label=Downloads&color=007AFF&cacheSeconds=300&v=2)
[![最新版本](https://img.shields.io/github/v/release/wm0104/RepoPocket?label=Release&color=007AFF&cacheSeconds=300&v=20261018)](https://github.com/wm0104/RepoPocket/releases/latest)

[下载 RepoPocket](https://github.com/wm0104/RepoPocket/releases/latest) · [TrollFools LSP 修改版插件源](https://github.com/wm0104/trollfools-repo)

**让 iOS 16 上的 GitHub 浏览，省心一点。**

你是否也遇到过：用苹果自带的 Safari 打开 GitHub，页面布局错乱、按钮挤在一起，想点开代码，却怎么也点不进去？

以为是网络问题，换了几个节点；怀疑是浏览器缓存，又清理了一遍。折腾到最后，代码还是看不了，文件也打不开。换用官方 App，有些想用的功能又不够顺手。

下面是 iOS 16.3 上实际遇到的 Safari 网页显示情况：

<table>
  <tr><th>GitHub 首页</th><th>仓库与代码页面</th><th>个人主页与贡献记录</th></tr>
  <tr>
    <td><img src="docs/images/safari-github-home-ios16.png" width="260" alt="iOS 16 Safari 打开 GitHub 首页时布局重叠、内容持续加载"></td>
    <td><img src="docs/images/safari-github-repository-ios16.png" width="260" alt="iOS 16 Safari 打开 GitHub 仓库时按钮重叠、代码列表显示异常"></td>
    <td><img src="docs/images/safari-github-profile-ios16.png" width="260" alt="iOS 16.3 Safari 打开 GitHub 个人主页时贡献记录挤压、文字异常换行"></td>
  </tr>
</table>

**RepoPocket 就是为解决这些日常使用中的不便而开发的。**

它是一款借助 **Codex 辅助开发**的 iOS GitHub 工具，让你通过 App 浏览仓库、阅读代码、下载文件，也能完成常用的仓库管理操作。

## App 预览

浏览仓库、查看代码目录、管理发行版，常用操作在 App 内完成。

<table>
  <tr>
    <th>仓库主页</th>
    <th>代码目录</th>
    <th>发行版</th>
  </tr>
  <tr>
    <td><img src="docs/images/app-repository-home.png" width="240" alt="RepoPocket 仓库主页，展示项目简介、协作入口与发行版"></td>
    <td><img src="docs/images/app-code-browser.png" width="240" alt="RepoPocket 代码目录，展示仓库文件夹和文件列表"></td>
    <td><img src="docs/images/app-releases.png" width="240" alt="RepoPocket 发行版列表，展示版本记录和新建发行版入口"></td>
  </tr>
</table>

### Git 功能预览

添加本地项目或克隆 GitHub 仓库，选择分支，在手机上管理项目文件与本地提交。

<table>
  <tr>
    <th>添加项目 / 克隆仓库</th>
    <th>选择仓库分支</th>
    <th>本地变更与提交</th>
  </tr>
  <tr>
    <td><img src="docs/images/app-git-clone.png" width="260" alt="RepoPocket 添加本地项目，选择仓库、分支和克隆位置"></td>
    <td><img src="docs/images/app-git-branches.png" width="260" alt="RepoPocket 选择 GitHub 仓库分支"></td>
    <td><img src="docs/images/app-git-project.png" width="260" alt="RepoPocket 本地 Git 项目，展示变更选择、文件导入、本地提交、拉取和推送"></td>
  </tr>
</table>

## 主要功能

📂 **浏览仓库与代码**<br>
查看仓库目录、文件内容和代码预览，切换分支、查看提交历史，在手机上也能方便地翻阅项目。

📖 **阅读项目自述文件**<br>
支持 README 排版、图片与徽章展示，可展开正文或进入全屏阅读，快速了解项目介绍和使用方法。

⬇️ **下载需要的文件**<br>
下载单个文件、整个仓库 ZIP、发行版附件和 Actions 构建产物，支持选择保存文件夹。

✏️ **编辑与提交文件**<br>
在具备权限的仓库中编辑文本、上传或删除文件，并提交到指定分支。

🌿 **管理本地 Git 项目**<br>
关联已有项目或克隆 GitHub 仓库，浏览和编辑文件、导入文件与文件夹、查看变更和差异；选择文件创建本地提交，再单独推送，支持仅快进拉取和查看本地提交历史。

⭐ **收藏与复刻仓库**<br>
为喜欢的项目添加星标，将仓库复刻到自己的账号，查看复刻来源和状态。

🔄 **同步上游更新**<br>
把其他仓库的更新拉到自己项目：先预览差异，在临时分支合并，确认后再更新目标分支；遇到冲突会停下，不会覆盖你的改动。

📦 **管理发行版**<br>
查看版本说明、下载附件，也能在有权限的仓库中创建、编辑发行版和管理附件。

⚙️ **查看 GitHub Actions**<br>
浏览工作流运行状态、任务与步骤，获取构建产物，并在具备权限时重新运行工作流。

👤 **多账号切换**<br>
支持添加和切换多个 GitHub 账号，按各账号的访问权限使用仓库功能。

## 插件与更多功能

- 编辑并上传 `.deb` 插件文件。
- 管理 `.dylib` 插件的版本、名称、作者等元信息，适配 LSP 版 TrollFools 插件源格式，不修改插件二进制代码。
- 查看 Issue / PR、讨论评论、审查记录、行内评论及 PR 文件差异。
- 创建仓库和分支，搜索仓库并按语言筛选、排序。
- 浏览用户资料、公开活动、关注动态、贡献者与语言统计。
- 发现近期新建的热门仓库和活跃开发者。
- 支持浏览器设备授权登录，以及跟随系统、浅色和深色外观。

RepoPocket 源于个人使用需求，借助 AI 辅助编写、调试和完善。**目前主要在 iOS 16 上测试**，功能仍在持续改进，欢迎反馈使用中遇到的问题。

系统要求：iOS 16 或更高版本，适用于 TrollStore。

**少一点反复刷新，多一点顺手浏览。**
