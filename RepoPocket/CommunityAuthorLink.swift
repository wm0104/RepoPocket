import SwiftUI

struct CommunityAuthorLink: View {
    @ObservedObject var api: GitHub
    let user: User?
    var date: String? = nil
    var opensInSheet = false
    @State private var showingProfile = false
    var body: some View {
        Group {
            if let user, !user.login.isEmpty {
                if opensInSheet {
                    Button { showingProfile = true } label: { identity }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("查看 " + user.login + " 的主页")
                } else {
                NavigationLink { UserRepositoriesView(api: api, user: user) } label: { identity }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("查看 " + user.login + " 的主页")
                }
            } else { identity }
        }
        .sheet(isPresented: $showingProfile) {
            if let user {
                NavigationStack {
                    UserRepositoriesView(api: api, user: user)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingProfile = false } } }
                }.appSheetCornerRadius()
            }
        }
    }
    private var identity: some View {
        HStack(spacing: 12) {
            GitHubAvatar(url: user?.avatar_url, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.login ?? "已删除用户").font(.headline).foregroundStyle(.primary)
                if let date { Text(ChinaDate.dateTime(date)).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(minHeight: 44)
    }
}
