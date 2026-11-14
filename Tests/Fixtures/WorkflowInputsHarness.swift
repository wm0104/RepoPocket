import Foundation

struct AppError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

// PRODUCTION_SCHEMA

@main struct WorkflowInputsHarness {
    static func denied(_ message: String, _ block: () throws -> Void) {
        do { try block(); preconditionFailure("Expected rejection: " + message) }
        catch { precondition(!error.localizedDescription.isEmpty) }
    }
    static func schema(_ input: String) throws -> WorkflowInputSchema {
        try WorkflowInputSchema.read("on:\n  workflow_dispatch:\n    inputs:\n" + input)
    }
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        for yaml in ["on: workflow_dispatch", "on: [push, workflow_dispatch]", "'on': {workflow_dispatch: {}}", "on:\n  workflow_dispatch:\n", "on:\n  workflow_dispatch:\n    inputs: {}"] {
            check(try WorkflowInputSchema.read(yaml).inputs.isEmpty)
        }
        for yaml in ["on: push", "on: [push, pull_request]", "on:\n  push:\n", "name: absent"] {
            denied("missing workflow_dispatch") { _ = try WorkflowInputSchema.read(yaml) }
        }
        let all = try schema("""
              title:
                description: 'A title: with # and ''quotes'''
                type: string
                required: true
                default: hello
              target:
                type: choice
                options: [stable, 'beta: preview', 'a,b']
                default: stable
              flag:
                type: boolean
              amount:
                type: number
                default: -1.5e2
              env:
                type: environment
                required: true
                default: production

        """)
        precondition(all.inputs.map(\.id) == ["title", "target", "flag", "amount", "env"])
        precondition(all.inputs[0].description == "A title: with # and 'quotes'")
        precondition(all.inputs[2].defaultValue == "false")
        let defaults = try all.values([:], environments: ["production"])
        precondition(defaults == ["title": "hello", "target": "stable", "flag": "false", "amount": "-1.5e2", "env": "production"])
        precondition(defaults["run_title"] == nil)
        denied("unknown input") { _ = try all.values(["run_title": "not declared"], environments: ["production"]) }
        denied("required empty") { _ = try all.values(["title": ""], environments: ["production"]) }
        denied("choice membership") { _ = try all.values(["target": "unlisted"], environments: ["production"]) }
        denied("boolean grammar") { _ = try all.values(["flag": "yes"], environments: ["production"]) }
        denied("environment membership") { _ = try all.values([:], environments: ["staging"]) }
        for invalid in ["NaN", "Infinity", "true", "1,2", "1_000", "0x10", "01", "1e999", " 1", "1 "] {
            denied("JSON number " + invalid) { _ = try all.values(["amount": invalid], environments: ["production"]) }
        }
        for valid in ["0", "-0", "-12", "0.5", "1e3", "-1.25E-2"] {
            _ = try all.values(["amount": valid], environments: ["production"])
        }
        for invalid in [
            "      bad: {type: future-type}\n",
            "      bad: {type: choice, options: []}\n",
            "      bad: {type: choice, options: [a, a]}\n",
            "      bad: {type: choice, options: [a, b], default: c}\n",
            "      bad: {type: choice, options: [a, b], default: ''}\n",
            "      bad: {type: string, options: [a]}\n",
            "      bad: {type: number, default: .nan}\n",
            "      bad: {type: boolean, default: yes}\n",
            "      bad: {type: string, unknown: value}\n",
            "      bad: {type: string, type: number}\n",
            "      bad: {type: string, default: null}\n",
            "      bad: {type: string, default: '${{ github.ref }}'}\n",
            "      bad: {type: string, default: !custom value}\n",
            "      bad: {type: choice, options: !custom [a]}\n",
            "      bad: {<<: {type: string}}\n"
        ] {
            denied("invalid schema " + invalid) { _ = try schema(invalid) }
        }
        denied("duplicate on") { _ = try WorkflowInputSchema.read("on: workflow_dispatch\non: push\n") }
        denied("multiple documents") { _ = try WorkflowInputSchema.read("on: workflow_dispatch\n---\non: push\n") }
        denied("file limit") { _ = try WorkflowInputSchema.read(String(repeating: "#", count: 512 * 1024 + 1)) }
        let many = (0..<26).map { "      key\($0): {type: string}\n" }.joined()
        denied("25 inputs") { _ = try schema(many) }
        let payload = try schema("      text: {type: string}\n")
        denied("payload limit") { _ = try payload.values(["text": String(repeating: "a", count: 65_536)], environments: []) }
        denied("UTF-8 conservative limit") { _ = try payload.values(["text": String(repeating: "中", count: 25_000)], environments: []) }
        check(try payload.values([:], environments: []).isEmpty)
        let folded = try schema("      text:\n        type: string\n        default: >-\n          first\n          second\n\n          paragraph\n")
        precondition(folded.inputs[0].defaultValue == "first second\nparagraph")
        let literal = try schema("      text:\n        type: string\n        default: |\n          a\n          b\n")
        precondition(literal.inputs[0].defaultValue == "a\nb\n")
        let legacy = try schema("      text: {description: legacy}\n")
        precondition(legacy.inputs[0].kind == .string)
        for value in ["2026-11-12", "yes", "on", "01"] {
            let text = try schema("      text: {type: string, default: \(value)}\n")
            precondition(text.inputs[0].defaultValue == value, "Do not coerce YAML 1.1 scalar strings")
        }

        // Unrelated jobs are real YAML, not schema. Flow maps, aliases, matrices and shell blocks must work.
        let complex = """
        name: Generic dispatch
        on: {workflow_dispatch: {inputs: {target: {type: choice, options: [stable, beta], default: stable}}}}
        env: &shared {MESSAGE: 'a: # b', CI: true}
        jobs:
          build:
            env: *shared
            strategy:
              matrix: {os: [ubuntu-latest, macos-latest], version: [1, 2]}
            runs-on: ${{ matrix.os }}
            steps:
              - uses: actions/checkout@v4
              - run: |
                  echo "on: workflow_dispatch is just shell text"
                  printf '%s\\n' '${{ github.ref }}'
              - env: {A: b}
                run: echo done
        """
        check(try WorkflowInputSchema.read(complex).inputs[0].options == ["stable", "beta"])
        let alias = """
        input: &input {type: string, default: 'kept'}
        on:
          workflow_dispatch:
            inputs:
              message: *input
        jobs: {build: {runs-on: ubuntu-latest}}
        """
        check(try WorkflowInputSchema.read(alias).inputs[0].defaultValue == "kept")

        // REAL_WORKFLOW_CHECKS
        print("PASS production Yams inputs schema: five types, defaults, membership, numeric grammar, unrelated complex jobs, literal on, missing dispatch, duplicate keys, aliases and payload limits")
    }
}
