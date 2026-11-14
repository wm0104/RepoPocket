import SwiftUI

struct WorkflowInputField: View {
    let input: WorkflowInputSchema.Input
    let environments: [String]
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(input.id + (input.required ? " · 必填" : " · 选填")).font(.headline)
            if !input.description.isEmpty { Text(input.description).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            switch input.kind {
            case .boolean:
                Toggle(input.id, isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" }))
                    .accessibilityValue(value == "true" ? "true" : "false")
                    .accessibilityIdentifier("workflow-input-\(input.id)")
            case .choice, .environment:
                NativeActionMenu(title: value.isEmpty ? "选择 \(input.id)" : value, symbol: nil,
                    accessibilityIdentifier: "workflow-input-\(input.id)", items: options.map { option in
                        NativeMenuItem(id: input.id + ":" + option, title: option, perform: { value = option })
                    } + (!input.required && input.defaultValue == nil ? [NativeMenuItem(id: input.id + ":unset", title: "不设置（省略此参数）", perform: { value = "" })] : []))
                    .workflowInputSelection(value.isEmpty ? "不设置（省略此参数）" : value)
                    .accessibilityValue(value.isEmpty ? "未设置" : value)
                if input.kind == .environment && environments.isEmpty { Text("仓库没有可选 environment。可选参数可留空；必填参数无法启动。").font(.caption).foregroundStyle(.secondary) }
            case .number, .string:
                TextField(input.kind == .number ? "数字（如 -1、0.5、1e3）" : "输入值", text: $value)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .keyboardType(input.kind == .number ? .numbersAndPunctuation : .default)
                    .frame(minHeight: 44)
                    .accessibilityLabel(input.id).accessibilityIdentifier("workflow-input-\(input.id)")
            }
            if let fallback = input.defaultValue {
                Text("默认值：" + (fallback.isEmpty ? "空字符串" : fallback)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var options: [String] { input.kind == .environment ? environments : input.options }
}
