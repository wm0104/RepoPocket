# DEB 编辑信息整合：本地验证记录

日期：2026-11-12。基线：`5edc0971b5b1c348f85268660e15a0f00b4e95ed`。

## 范围和交互核对

仅在现有 `DebEditorView` 的“编辑”软分组加入发布日期与当前版本更新信息；不增加卡片、菜单、预览、保存入口或富文本工具栏。保留原文件选择、系统 sheet/alert、无动画折叠、生成副本、分享、本地保存及远端提交按钮行为。呈现调用链为仓库文件/上传队列/本地项目 → 现有编辑页 → `DebControlEditor.edit` → 生成重读验证 → 原有后续按钮；没有实施新的返回、Tab、Git 或 Actions 功能。

`AGENTS.md` 与 wm14/native-ui/ponytail 已读取。`.codegraph` 仅有占位 `.gitignore`，本机无 `codegraph` 命令；本次依据源码和调用方核对，不声称执行了图索引分析。

## 保存语义

- Description 的续行 ` .` 或制表符后单个点解码为空行；修改后空行编码成 ` .`。摘要不能为空，新写入续行不能只含空白或单个点。未改 Description 不重写其原始字段拼写、缩进和空段落；其他未修改字段及合法尾部分隔空行也保留。
- 日期优先独立 `X-WM0104-Release-Date`，其次当前 Version 匹配且日期合法的日志日期，最后取本地系统当天。独立字段中无效的已存日期保留显示，必须更正才能生成。
- 日期严格使用 Gregorian `YYYY-MM-DD`，校验真实日历日期和格式；没有日志仍保存独立日期。
- `X-WM0104-Changelog` 格式为 `版本 | 日期 | 条目1；条目2`。输入每行一条，去除条目两侧空白和空条目；拒绝条目内“；”和“ | ”及控制字符。Markdown 星号原样保留，换行往返仍为逐条日志。
- 优先读取统一日志；仅 `com.wm0104.repopocket` 兼容读取 `X-RepoPocket-Changelog`。清空时真正删除统一字段，指定包的旧字段也删除，避免复活；其他包旧字段、未知字段保留。原指定包改包名时仍删除其旧字段。
- 改 Version 不重新载入日志，当前编辑内容按新 Version 保存；不改文件名、不改 Release 标签，不把被编辑包强制设为 App 版本。
- 新增字段、删除字段均纳入差异列表；生成后重读同时验证值和字段不存在。旧非 UI 调用若未传 releaseDate，保留已有日期日志。
- 继续使用源文件安全副本、独占新建输出、data.tar 精确成员字节/SHA 校验和非 control 成员保护，无 Fila 后端依赖。

借鉴 Fila `70820797f29dabbb78e58d48328401ef0e99e5b5` 的 `DebianPackageInformation.swift` 日期、日志与 Description 语义，已补仓库及应用内准确来源声明，沿用完整 OwnGoal Studio MIT 许可。

## 红绿与本地检查

1. 先增加 `Tests/test_deb_ui_static.py` 的字段、回填、输入和删除校验断言，在实现前运行失败（新增字段尚不存在）；实现后通过。这是静态契约红绿，不是 Swift 运行红绿。
2. `python3 Tests/test_swift_structure.py` 通过：160 个 Swift 源文件的括号/字符串结构检查；不等于编译。
3. `python3 Tests/test_packages.py`：21/21 通过（本地合成夹具/模拟签名工具测试，不是真实产物构建）。
4. `python3 Tests/test_ios15_compatibility.py`：12/12 通过（静态）。
5. `Tests/test_soft_groups.py` 首次检测到原业务字节冻结断言失败；仅定点兼容本轮授权的回填、输入参数与重读校验新增行，其他呈现/提交/安全副本函数仍维持原冻结检查；随后宿主测试通过。
6. 复用外置缓存现有 `RepoPocket-analysis/run-host-tests.py <仓库路径>`：454 项，0 失败、0 错误，其中实际通过 313 项、跳过 141 项；另有 8 个依赖 Swift 的模块未加载，不能计为通过。
7. `python3 Tests/test_four_packages_workflow.py`：3/3；`python3 Tests/test_build_workflow.py`：13/13；`python3 Tests/test_final_publish.py`：2 通过、1 跳过。均为本地配置检查。
8. 在外置缓存运行 `DebControlEditorTests/fixtures.py` 副本，生成 19 个纯本地合成 DEB；Python AST 检查通过。没有下载、安装或处理真实包。
9. `git diff --check` 通过。

## 已添加但未执行的 Swift 回归

扩展既有 `DebControlEditorTests/Harness.swift` 与 `fixtures.py`，不需要新增 CI 入口，现有 `sh DebControlEditorTests/run-macos.sh` 会执行：合法/非法日期、独立日期优先与无日志保存、日志清空、指定包旧字段防复活与其他包保留、改版本、Markdown 加粗标记往返、Description 空段落、未改缩进/字段/尾部空行、源文件与 data 成员不变，以及生成重读校验。Python 独立归档检查同步覆盖新增输出。

本机 `command -v swiftc` 无输出，因此未运行该 Swift 测试脚本、未编译 App。没有以跳过或静态通过替代 Swift 运行结果。

## 四产物及版本边界

`project.yml` 的 MARKETING_VERSION 和 CURRENT_PROJECT_VERSION 已为 `1.2.0`，本次保持不变。`.github/workflows/build.yml`、`Scripts/`、签名、最低系统和架构配置均无差异。现有四产物路径保留：

- `dist/RepoPocket.ipa`
- `dist/RepoPocket.tipa`（现有流程由 IPA 复制并 cmp）
- `dist/RepoPocket_1.2.0_iphoneos-arm64e.deb`
- `dist/RepoPocket_1.2.0_iphoneos-arm64.deb`

两种 DEB 是同一 arm64 App 的不同打包 flavor；DEB 包架构标签不代表 App Mach-O 为 arm64e。本轮不构建、不触发 CI、不上传、不下载包、不安装、不 commit/push。

新增 UI 仅使用已有 TextField、TextEditor、caption、accessibilityIdentifier；日期输入使用 iOS 15 可用的 textInputAutocapitalization 与 disableAutocorrection(true)，不复制页面其他字段已有的 autocorrectionDisabled 写法。未引入无 guard 的 iOS 16/17 专属 API；源码沿用 iOS 15 最低系统配置，目标覆盖 iOS 15～17。此为源码兼容核对，不是编译或真机兼容验收。四种分发形式不意味着所有 iOS 15～17 都能安装：TrollStore 与越狱各有对应系统、设备及环境限制，不能宣称任意 iOS 17 均支持。

源生成器的 Markdown 列表支持不等于 Sileo 真机已验收；Swift 编译、归档回归执行、真机表单/键盘/动画/可访问性与四包真实构建均未验证。
