#if DEBUG
import SwiftUI

/// Network-free replay of shared row boundaries in List and Form hosts.
struct SoftGroupLifecycleStylePreview: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach(["仓库", "本地 Git", "设置"], id: \.self) { name in
                    NavigationLink(name) { SoftGroupLifecyclePage(name: name) }
                }
            }.navigationTitle("分组回归")
        }.preferredColorScheme(.light)
    }
}
private struct SoftGroupLifecyclePage: View {
    let name: String
    @State private var expanded = false
    @ViewBuilder private var rows: some View {
        Section {
            SoftGroupRows {
                SoftGroupRow("first") {
                    NavigationLink("查看详情") { Text("详情内容").navigationTitle("详情") }
                        .accessibilityIdentifier("boundary-first")
                }
                if expanded { SoftGroupRow("extra") { Text("刷新后的内容").frame(minHeight: 64) } }
                SoftGroupRow("last") { Text("分组末尾").accessibilityIdentifier("boundary-last") }
            }
        }
        Section {
            SoftGroupRows {
                SoftGroupRow("single") { Text("独立分组").accessibilityIdentifier("boundary-single") }
            }
        }
    }
    var body: some View {
        Group {
            if name == "设置" { Form { rows } }
            else { List { rows }.listStyle(.insetGrouped) }
        }.navigationTitle(name)
        .refreshable { expanded.toggle() }
        .toolbar { Button("刷新") { expanded.toggle() } }
    }
}
#endif
