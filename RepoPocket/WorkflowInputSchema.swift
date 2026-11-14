import Foundation
import Yams

/// Parse YAML with Yams; validate only the manual-dispatch schema, never unrelated jobs.
struct WorkflowInputSchema: Equatable {
    enum Kind: String { case string, choice, boolean, number, environment }
    struct Input: Equatable, Identifiable {
        let id: String
        let description: String
        let kind: Kind
        let required: Bool
        let defaultValue: String?
        let options: [String]
    }
    let inputs: [Input]

    static func read(_ text: String) throws -> Self {
        guard text.utf8.count <= 512 * 1024 else { throw failure("工作流超过 512 KiB 读取上限。") }
        let document: Node
        do {
            // Keep literal YAML 1.2-style scalar text; YAML 1.1 must not coerce on / yes / date strings.
            guard let node = try Yams.compose(yaml: text, .basic.appending(.null)) else { throw failure("工作流 YAML 为空。") }
            document = node
        } catch { throw failure("无法读取工作流 YAML：" + error.localizedDescription) }
        let root = try WorkflowInputYAML.mapping(document)
        guard let trigger = root["on"] else { throw failure("未声明 workflow_dispatch，不能手动启动。") }
        let dispatch: Node
        switch trigger {
        case .scalar:
            let event = try WorkflowInputYAML.string(trigger)
            guard event == "workflow_dispatch" else { throw failure("未声明 workflow_dispatch，不能手动启动。") }
            return .init(inputs: [])
        case .sequence(let events):
            guard try events.map({ try WorkflowInputYAML.string($0) }).contains("workflow_dispatch") else { throw failure("未声明 workflow_dispatch，不能手动启动。") }
            return .init(inputs: [])
        case .mapping:
            let events = try WorkflowInputYAML.mapping(trigger)
            guard let value = events["workflow_dispatch"] else { throw failure("未声明 workflow_dispatch，不能手动启动。") }
            dispatch = value
        }
        if WorkflowInputYAML.isNull(dispatch) { return .init(inputs: []) }
        let config = try WorkflowInputYAML.mapping(dispatch)
        guard Set(config.keys).isSubset(of: ["inputs"]) else { throw failure("workflow_dispatch 含未知配置，无法安全读取。") }
        guard let node = config["inputs"], !WorkflowInputYAML.isNull(node) else { return .init(inputs: []) }
        let fields = try WorkflowInputYAML.mapping(node)
        guard fields.count <= 25 else { throw failure("GitHub 最多支持 25 个 inputs。") }
        let inputs = try node.mapping!.map { pair -> Input in
            let name = pair.key.scalar!.string
            guard !name.isEmpty, !name.contains("${{") else { throw failure("无效 input 名称。") }
            let field = try WorkflowInputYAML.mapping(fields[name]!)
            guard Set(field.keys).isSubset(of: ["description", "required", "default", "type", "options"]) else { throw failure("输入 \(name) 含未知字段。") }
            // Legacy workflow_dispatch inputs without type are strings.
            let type = try field["type"].map(WorkflowInputYAML.string) ?? "string"
            guard let kind = Kind(rawValue: type) else { throw failure("输入 \(name) 的类型 \(type) 暂不支持，已禁止启动。") }
            let requiredText = try field["required"].map(WorkflowInputYAML.string) ?? "false"
            guard ["true", "false"].contains(requiredText) else { throw failure("输入 \(name) 的 required 必须为 boolean。") }
            let options: [String]
            if let values = field["options"] {
                guard case .sequence(let list) = values, values.tag == Tag(.seq), kind == .choice else { throw failure("输入 \(name) 的 options 仅支持 choice 列表。") }
                options = try list.map { try WorkflowInputYAML.string($0) }
            } else { options = [] }
            guard kind != .choice || (!options.isEmpty && Set(options).count == options.count && options.allSatisfy { !$0.isEmpty }) else { throw failure("输入 \(name) 的 choice 选项为空或重复。") }
            let fallback = kind == .boolean ? "false" : nil
            let value = try field["default"].map(WorkflowInputYAML.string) ?? fallback
            if kind == .choice, let value, !options.contains(value) { throw failure("输入 \(name) 的默认值不在 choice 选项中。") }
            let input = Input(id: name, description: try field["description"].map(WorkflowInputYAML.string) ?? "", kind: kind,
                              required: requiredText == "true", defaultValue: value, options: options)
            if let value, let issue = issue(input, value: value, environments: nil, checkRequired: false) { throw failure("默认值无效：\(name)：\(issue)") }
            guard !(value?.contains("${{") ?? false), !options.contains(where: { $0.contains("${{") }) else { throw failure("inputs 默认值或选项中的动态表达式暂不支持。") }
            return input
        }
        return .init(inputs: inputs)
    }

    func values(_ values: [String: String], environments: [String]) throws -> [String: String] {
        guard Set(values.keys).isSubset(of: Set(inputs.map(\.id))) else { throw Self.failure("参数不属于当前工作流，请重新加载。") }
        var result: [String: String] = [:]
        for input in inputs {
            let value = values[input.id] ?? input.defaultValue ?? ""
            if let issue = Self.issue(input, value: value, environments: environments) { throw Self.failure("\(input.id)：\(issue)") }
            // Optional unset inputs are omitted, preserving GitHub's own fallback behavior.
            if !value.isEmpty || input.defaultValue != nil { result[input.id] = value }
        }
        let bytes = try JSONSerialization.data(withJSONObject: result)
        guard bytes.count <= 65_535 else { throw Self.failure("inputs 超过 65,535 字节安全上限。") }
        return result
    }
    private static func issue(_ input: Input, value: String, environments: [String]?, checkRequired: Bool = true) -> String? {
        if value.isEmpty { return checkRequired && input.required ? "必填项不能为空" : nil }
        switch input.kind {
        case .boolean: return ["true", "false"].contains(value) ? nil : "必须为 true 或 false"
        case .number:
            // JSON number grammar, no NaN/Infinity/hex or locale-specific separators.
            guard let data = ("[" + value + "]").data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [NSNumber], array.count == 1,
                  CFGetTypeID(array[0]) != CFBooleanGetTypeID(), array[0].doubleValue.isFinite,
                  value.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return "请输入有限 JSON 数字" }
            return nil
        case .choice: return input.options.contains(value) ? nil : "必须选择声明的选项"
        case .environment: return environments.map { $0.contains(value) ? nil : "必须选择仓库中现有的 environment" } ?? nil
        case .string: return nil
        }
    }
    static func failure(_ message: String) -> AppError { AppError(text: message) }
}

import CoreFoundation

private enum WorkflowInputYAML {
    static func isNull(_ node: Node) -> Bool { node.tag == Tag(.null) }
    static func string(_ node: Node) throws -> String {
        guard let scalar = node.scalar, !isNull(node),
              [Tag(.str), Tag(.bool), Tag(.int), Tag(.float)].contains(node.tag) else {
            throw WorkflowInputSchema.failure("inputs 配置预期普通标量；null、复杂值或自定义 YAML tag 不支持。")
        }
        return scalar.string
    }
    static func mapping(_ node: Node) throws -> [String: Node] {
        guard let mapping = node.mapping, node.tag == Tag(.map) else { throw WorkflowInputSchema.failure("inputs 配置预期 YAML 映射。") }
        var result: [String: Node] = [:]
        for pair in mapping {
            // Read the literal key, not YAML 1.1 bool conversion (which would turn `on` into true).
            guard let key = pair.key.scalar?.string, !key.isEmpty, key != "<<", result[key] == nil else {
                throw WorkflowInputSchema.failure("工作流相关配置含重复键、复杂键或 merge key，无法安全读取。")
            }
            result[key] = pair.value
        }
        return result
    }
}
