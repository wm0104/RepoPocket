# RepoPocket 四包封装：纯 App deb

## 产物与身份

| 产物 | 用途 / 根布局 |
| --- | --- |
| IPA / TIPA | 同内容 TrollStore 应用归档；本脚本不生成、修改或重签 IPA/TIPA |
| `RepoPocket_1.2.0_iphoneos-arm64e.deb` | roothide；`Applications/RepoPocket.app`，空前缀交由目标 dpkg 重定位 |
| `RepoPocket_1.2.0_iphoneos-arm64.deb` | rootless；`var/jb/Applications/RepoPocket.app` |

两类安装方式沿用 `com.wm0104.RepoPocket`，Share 为 `com.wm0104.RepoPocket.Share`；不支持并存，不改 bundle 身份规避冲突。Debian Package 固定小写 `com.wm0104.repopocket`（符合 Debian 小写字母/数字/`+-.` 命名规则）；两个 flavor 不同时安装。版本默认读取 App Info.plist，本次均为 `1.2.0`，必须与主 App/Share 的短版本和构建版本一致；没有 flavor 版本后缀。

Deb 只含 App（含 Share.appex、Frameworks 和资源）及 `DEBIAN/control`。依赖仅 `firmware (>= 15.0), uikittools`；Section 为 Utilities。没有 daemon、helper、FilaBackend、LaunchDaemons、launchctl 依赖或 maintainer hooks，更不会卸载 TrollStore 应用、删除用户数据或手写 uicache 注册命令。

## macOS / workflow 调用

现有构建应先完成原 entitlements 的 codesign 签名和 `codesign --verify --deep --strict`，再调用：

```bash
brew install dpkg
# python3 必须可用；若 runner 未预装：brew install python
APP=build/Build/Products/Release-iphoneos/RepoPocket.app
bash Scripts/package-deb.sh --app "$APP" --output "$PWD/dist" --flavor roothide
bash Scripts/package-deb.sh --app "$APP" --output "$PWD/dist" --flavor rootless
python3 Scripts/verify-deb.py verify --deb dist/RepoPocket_1.2.0_iphoneos-arm64e.deb --flavor roothide --version 1.2.0
python3 Scripts/verify-deb.py verify --deb dist/RepoPocket_1.2.0_iphoneos-arm64.deb --flavor rootless --version 1.2.0
(cd dist && shasum -a 256 -c RepoPocket_1.2.0_iphoneos-arm64e.deb.sha256 && shasum -a 256 -c RepoPocket_1.2.0_iphoneos-arm64.deb.sha256)
```

**默认 `--sign-mode preserve`**：验证后逐字节复制已签 App，不需要 ldid；macOS 除逐 slice 的 CodeDirectory 检查外，要求源 App、stage App 和最终 deb 解出的 App 全部通过系统 codesign deep/strict 检查。不修改源 App，也不触碰 IPA 原签名基线。工作流不必为此安装 ldid。

仅对明确的未签编译输入，可选：

```bash
brew install ldid
bash Scripts/package-deb.sh --app "$APP" --output "$PWD/dist" --flavor roothide --sign-mode ldid
```

该模式只重签私有 stage：最深层 framework/dylib → Share → App，使用原仓库主 App/Share entitlements，framework/dylib 空 entitlements；然后 Procursus ldid 的 bundle `-s` 在保留每个二进制 entitlements 的同时由内向外重建资源 seals。实际 ldid bundle 支持和 macOS codesign 互操作仍须在 macOS 运行验收；不将 Linux mock 签名测试冒充原生签名成功。若工具版本不支持或验签失败，拒绝发布；不要禁用检查强行打包。

每个 deb 伴随 `.deb.sha256` 和 `.deb.verification.json`，后者包括 control/flavor、逐 Mach-O slice 的架构/最低系统/entitlement 键名、所有文件 SHA256；不输出 entitlement 值或签名工具 stderr。输出已存在时拒绝覆盖。临时 stage 只属于本次调用；失败清理，不留下半成品。源 App 输入与输出不可嵌套，源树拒绝软/硬链接、特殊文件、开发/封装杂项；打包前后对源树内容和权限做快照比较。

## 容器与注册证据（2026-11-11）

没有添加 deb 专属权限文件，直接保留原 `Entitlements.plist` 与 `ShareExtension/Entitlements.plist`：TROLLTROLL application/team identifier、共享 group、钥匙串范围等原样继承，不复制 Fila 的 platform/no-sandbox、存储授权或后端授权。

可复核的上游源：

1. [ProcursusTeam/uikittools-ng @6b84d792](https://github.com/ProcursusTeam/uikittools-ng/blob/6b84d79261186d070b54efa9a39850f108b52239/uicache.m#L280-L299)：`constructContainerizationForEntitlements` 缺少 container-required 时默认 YES；布尔 false 禁用容器；布尔 true 保留容器；**字符串**才指定自定义 container ID。注册时默认 App bundle ID / Share bundle ID（约 L321-L325、L398-L401），分别创建 MCMAppDataContainer / MCMPluginKitPluginDataContainer；group 由签名 entitlements 建立。
2. [roothide/uikittools-ng @627e1eeb](https://github.com/roothide/uikittools-ng/blob/627e1eebea4d49244f8065b09d9ad93a2eef4c1e/uicache.m#L283-L318)：同样缺省 YES，额外 no-sandbox=true 会返回 NO；不能为了 roothide 无依据加 no-sandbox。插件注册强制容器化（约 L415-L421）。RepoPocket 原基线没有 no-container/no-sandbox/container-required，因此不需要添加布尔或字符串容器 override；既有 Documents 的容器语义应保留。
3. [roothide/Procursus-roothide @7dfa18ef](https://github.com/roothide/Procursus-roothide/blob/7dfa18ef09d18028f4e2bca01ce28c3e7e0db227/makefiles/uikittools.mk)：uikittools 2.1.8 固定引用上述 roothide commit；`build_info/uikittools.triggers.iphoneos` 监听 `@MEMO_PREFIX@/Applications`，其 postinst 在 triggered 时运行 uicache。App 包本身不写 maintainer hooks。rootless 也依赖目标 bootstrap 的对应触发器，不能把一个上游版本的源码结论冒充所有历史 bootstrap 的实测。
4. 已缓存 Fila 参考的 `Documentation/Packaging.md` 说明依赖 uikittools triggers；其 daemon/launchctl/高权限与本 App 无关，未复用。

源码及外置验证缓存位于 `RepoPocket-analysis/ios15-fourpackages/evidence/`。这些是源码证据，不是目标设备注册结果，也不证明升级/切换后的数据自动迁移。

**升级注册限制：**上述 uikittools 的 `uicache -a` 会跳过已经在相同路径登记的应用（标准版约 L558–562，RootHide 约 L720–729）；因此默认触发器可作为首次安装候选方案，不能保证升级后的扩展或签名变动被重新登记。本轮包保持权限和扩展身份不变，不加入未经设备验证的自动注册/注销 hook；如未来改变扩展或权限，须先在两种 bootstrap 验证定向 `uicache -p` 流程，再提供可靠升级支持。不能以图标存在代替扩展和 App Group 的运行验收。

## 验收与边界

```bash
PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_packages.py -v
```

测试使用真实 dpkg-deb 构造与解析 deb、合成 arm64 Mach-O/真实 SHA256 CodeDirectory，以及显式的 test-only ldid/codesign 替身（不执行任何 payload）。覆盖双布局/control 与交叉 flavor 拒绝、源内容/权限不可变、unsigned 仅 stage 签名路径、签名破坏、错误版本/注入、symlink、输出嵌套、隐藏额外 Mach-O、额外 daemon/hook、失败清理及多 slice 架构/最低系统/平台拒绝。

生产检查所有 Mach-O（含 Share 与嵌套 framework/dylib）的每个 slice：64 位 arm64/arm64e iOS-device，必须至少有 arm64；允许 arm64+arm64e，不把 Debian iphoneos-arm64e 错当成必须把主程序编译为 arm64e。每个 slice 的 LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS 必须存在且最低系统 <=15.0；App/Share Info 最低系统必须恰为 15.0。签名读回逐 slice 比对原 entitlement 字典，验证 CodeDirectory 代码页及嵌入 entitlement hashes；macOS 再做 bundle/resource seals 校验。Linux 检查不等于 CMS/AMFI 信任或 iOS 加载成功。

**设备边界：**未安装手机、未执行真实 iOS 构建或真机注册。TrollStore 不是全 iOS 17 通用支持；需设备/系统版本属于其实际支持范围。deb 依目标 roothide/rootless bootstrap、dpkg 架构与 uikittools 实现，iOS 15.0 下限不是所有设备都能越狱的承诺。切换 TrollStore/deb 前先自行备份导出 Documents/仓库/共享数据，不混用安装方式；现有容器、App Group、钥匙串和卸载/升级行为都需目标设备分别验证，不承诺数据自动迁移。
