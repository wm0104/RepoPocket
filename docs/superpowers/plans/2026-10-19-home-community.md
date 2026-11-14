# RepoPocket 1.0.9 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成已批准的首页分组、列表搜索、议题回复和按日活动图。
**Architecture:** 复用仓库集合页、账号隔离的GitHub读取通道和分组行。新逻辑用独立Foundation模型，界面与模型分离；议题和活动的请求由页面状态持有。
**Tech Stack:** Swift 5、SwiftUI、Foundation、XCTest、现有Python原生测试夹具。
**Spec:** ../specs/2026-10-19-home-community-design.md

## Global Constraints
- iOS16，版本1.0.9，无新依赖，README不改。
- 22点连续圆角，沿用分隔线；账号切换隔离；无滚动刷新。
- 只通过Actions交付IPA；用户已于最终验证期间取消关机要求。

## Review Focus
- 过滤后空结果、单行、多行的分组边界和分页范围提示。
- 议题搜索排除PR，API URL中仓库解析严格，账号切换不可显示旧数据。
- 引用回复嵌套引文、删除用户、空正文、Unicode及总长度上限。
- 活动截断在同一天、无记录、非法日期、跨月跨年和北京时间日期边界。
- 页面返回、滑动和失败后保持状态，刷新取消旧请求且可显式重试。

### Task 1: 首页与四个列表搜索
Files: RepositorySections.swift, RepoPocketApp.swift, UserConnectionsView.swift, ListSearchField.swift; Tests/test_home_community.py, StyleUITests.
- [x] 添加失败的主页导航/搜索UI契约和原生过滤测试。
- [x] 合并首页入口；复用集合页，统一显式搜索框；添加无结果与范围提示。
- [x] 本地契约检查、CI原生和模拟器验证。

### Task 2: 我的议题与明确引用回复
Files: HomeCommunityModels.swift, PersonalIssuesView.swift, CommunityAPI.swift, CollaborationViews.swift, CollaborationComposer.swift.
Interfaces: PersonalIssueFilter; PersonalIssueRules.repository(item), query(login,filter); CommentReplyContext.body(reply,repo,number).
- [x] 为查询、来源、引用和空回复写原生回归夹具。
- [x] 首页显示3条；独立分页列表和筛选；评论对应对象和实际引用内容一致。
- [x] 验证取消不发送、发送确认和账号隔离。

### Task 3: 按日公开活动
Files: ActivityCalendar.swift, ActivityCalendarView.swift, NativeStatisticsView.swift.
Interfaces: ActivityDay; ActivityCalendar.days(events,exhausted,now); ActivityCalendarStore.load(refresh,api,login).
- [x] 写日期、去重、部分覆盖、零与未知的回归夹具。
- [x] 30天方格、选日活动、3页首次预算与300条总上限。
- [x] 真实模拟器点击及截图检查。

### Task 4: 审查与交付
- [x] 版本配置与包内校验改1.0.9；新测试加入Build IPA及所有原生检查入口。
- [x] 完整分支独立审查；处理重要问题；同步main并运行工作流。
- [x] 核对最终构建SHA与非空产物，并按实际变更范围匹配原生和界面验证证据。

最终验证期间用户已返回并明确要求不关机；完成后仅报告结果。

### Task 5: 已批准的议题长按删除
Files: IssueDeletion.swift (身份、权限响应、会话上下文及共享状态), IssueDeletionUI.swift (菜单与确认), GitHub.swift (账号绑定GraphQL传输), PersonalIssuesView.swift, CollaborationViews.swift; Tests/test_issue_deletion.py, StyleUITests/StyleBoundaryTests.swift, UserConnectionsStylePreview.swift。
Interfaces: IssueDeletionSubject(item,repo); IssueDeletionGrant; IssueDeletionConfirmation; IssueDeletionState.load(subjects,api), remove(confirmation,api); GitHub.issueDeletionGraphQL(query,variables), issueDeletionGrants(subjects), deleteIssue(confirmation)。同一GitHub实例共享删除状态，页面各自持有确认目标，避免叠加对话框。
- [x] 写失败的菜单覆盖契约和生产Swift回归：权限定向、身份错误、GraphQL错误、空响应、会话过期、重复确认与成功回执。
- [x] 按页批量读取viewerCanDelete并缓存，复核后执行deleteIssue；共享已删除ID只在成功后更新。议题列表在计算圆角边界前过滤已删除记录；PR使用独立ID空间，不能应用议题删除过滤。
- [x] 为首页和仓库列表添加一致的长按菜单、取消/删除确认及失败提示；滚动不请求，失败允许手动重查权限。
- [x] 使用隔离URLProtocol验证首页、全部议题和仓库议题菜单、取消不删除及确认后移除；完善现有DEB空字段无障碍断言，保留严格保存重开验证。
- [x] 独立审查，修复重要问题，同步main；核对工作流、非空IPA和原生界面结果。浏览器方案不实施，电脑保持开机。

### Verification Evidence
- 长按删除运行代码：1223df12454f9950c97b7177cc04e2fb79cc1cf6，已同步main；独立审查发现的Issue/PR ID空间问题已修复并通过复查。
- 主分支Local Git检查39251861260成功；Build IPA39251242891成功，产物RepoPocket为4,837,267字节、非过期。
- 主分支Native UI39251861160：21项、0失败。三处取消/确认删除测试118.925秒，原有DEB修改并保存重开测试37.025秒；三处确认截图已检查。
- 用户随后要求底部“仓库”页签改“主页”，图标改为house。fba30f3只改这一行，以上界面夹具覆盖的删除实现完全相同；不重复执行相同模拟器夹具。对fba30f3单独启动完整Build IPA39254346212，包含全部原生回归和iOS编译/打包。
- 最终Build IPA39254346212成功，运行SHA为fba30f3d07480bd6e758a7ce0fc854dd21b058bf，产物RepoPocket为4,837,134字节、非过期；包内应用及扩展版本校验均为1.0.9。文档收尾提交不改运行代码。

### Implementation Decisions
- 沿用用户既有批准直接执行，无须重复询问方案确认。Windows没有Swift/Xcode，原生Swift、iOS编译及界面测试交给macOS工作流；本地静态检查与实际原生验证分开记录。
- 关注列表搜索筛选已加载页并显示范围及加载更多；仓库集合原有逻辑加载全部页。未加载的用户不会被当前本地搜索命中，避免隐式逐用户读取。
- 主页页签的一行名称/图标修改后单独跑完整Build IPA；沿用之前通过的21项相同界面夹具，不把它们声称为fba30f3的重新执行结果。该夹具不经过运行时TabView，因此重复执行也不会增加页签图标的设备验证证据。
- 独立审查的重要问题均已修复，无遗留审查项。未执行真实GitHub议题删除，也未执行关机。
