import SwiftUI

struct DeviceOAuthView: View {
    @ObservedObject var api: GitHub
    @EnvironmentObject private var presentation: AccountPresentation
    @Environment(\.openURL) private var openURL
    @AppStorage("github.oauth.clientID") private var clientID = ""
    @StateObject private var controller = DeviceOAuthController()
    @State private var privateRepositories = false
    @State private var followUsers = false
    var body: some View {
        Form {
            Section("GitHub 浏览器授权") {
                SoftGroupRows {
                SoftGroupRow("client") { TextField("你的 OAuth App Client ID", text: $clientID).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(controller.busy) }
                SoftGroupRow("scope") { Toggle("授权私有仓库访问", isOn: $privateRepositories).disabled(controller.busy) }
                SoftGroupRow("follow") { Toggle("授权关注与取消关注", isOn: $followUsers).disabled(controller.busy) }
                if followUsers { SoftGroupRow("follow-help") { Text("额外请求 user:follow 权限，用于管理当前账号的关注关系。").font(.caption).foregroundStyle(.secondary) } }
                SoftGroupRow("help") { Text(privateRepositories ? "请求 read:user、repo 权限。" : "请求 read:user、public_repo 权限。私有仓库及某些管理操作可继续使用原来的 Token 登录。")
                    .font(.caption).foregroundStyle(.secondary) }
                if controller.busy {
                    SoftGroupRow("busy") { ProgressView("等待 GitHub 授权…") }
                    if !controller.userCode.isEmpty {
                        SoftGroupRow("code") { Text(controller.userCode).font(.title.monospaced()).textSelection(.enabled).accessibilityLabel("授权码 " + controller.userCode) }
                        SoftGroupRow("copy") { Button("复制授权码") { UIPasteboard.general.string = controller.userCode } }
                    }
                    if let url = controller.verificationURL { SoftGroupRow("open") { Button("打开 GitHub 输入授权码") { openURL(url) } } }
                    SoftGroupRow("cancel") { Button("取消授权", role: .cancel) { controller.cancel() } }
                } else {
                    SoftGroupRow("start") {
                    Button("开始授权") {
                        controller.start(clientID: clientID, privateRepositories: privateRepositories, followUsers: followUsers, api: api) { presentation.showing = false }
                    }.disabled((try? DeviceOAuthRules.clientID(clientID)) == nil)
                    }
                }
                if !controller.message.isEmpty { SoftGroupRow("message") { Text(controller.message).font(.callout) } }
                }
            }
            Section("首次配置") {
                SoftGroupRows {
                SoftGroupRow("setup") { Text("在自己的 GitHub 账号下创建 OAuth App 并启用 Device Flow，然后将 Client ID 填到这里。无需填写 Client Secret，也不需要部署服务器。") }
                SoftGroupRow("apps") { Link("管理自己的 OAuth Apps", destination: URL(string: "https://github.com/settings/developers")!) }
                SoftGroupRow("docs") { Link("GitHub 官方设备授权说明", destination: URL(string: "https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow")!) }
                }
            }
        }.navigationTitle("浏览器授权登录").adaptiveWorkspaceLayout()
        .onDisappear { controller.cancel() }
    }
}
