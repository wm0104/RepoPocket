import SwiftUI

struct ListSearchButton: View {
    @Binding var visible: Bool
    @Binding var query: String
    let title: String
    var body: some View {
        Button {
            visible.toggle()
            if !visible { query = "" }
        } label: { Image(systemName: visible ? "xmark" : "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }
        .accessibilityLabel(visible ? "关闭搜索" : "搜索" + title)
        .accessibilityIdentifier("list-search-button")
    }
}
struct ListSearchField: View {
    @Binding var query: String
    let title: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索" + title, text: $query).focused($focused)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("list-search-field")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).accessibilityLabel("清空搜索")
            }
        }.task { focused = true }
    }
}
