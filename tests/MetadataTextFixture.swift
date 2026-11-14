import Foundation
struct AppError: Error { let text: String }
struct WorkspaceBinding {}

let original = #"""
{
  "repository_name": "owner/Repo",
  "other": "中文 \u263A [not an array]",
  "unknownRoot": [{"nested":[1,2]}],
  "packages": [
    {"dylib":"https://owner.github.io/Repo/downloads/%E4%B8%AD%E6%96%87.dylib","name": "旧名", "version":"1", "section":"自定义", "description":"keep https://x/a:b", "unknown": [1,{"x":true}]},
    { "dylib": "https://other.example/a.dylib", "name": "其它" }
  ]
}
"""# + "\n"
let raw = Data(original.utf8)
let updated = try TrollMetadata.updating(raw: raw, repo: "owner/Repo", branch: "main", path: "downloads/中文.dylib", fields: ["name":"新名", "version":"2"])
let expected = original.replacingOccurrences(of: "\"旧名\"", with: "\"新名\"").replacingOccurrences(of: "\"version\":\"1\"", with: "\"version\":\"2\"")
precondition(updated == Data(expected.utf8), "Only requested value spans may change")
let inserted = try TrollMetadata.updating(raw: raw, repo: "owner/Repo", branch: "main", path: "downloads/中文.dylib", fields: ["name":"引号\"和换行\n", "version":"2", "author":"甲"])
let parsed = try JSONSerialization.jsonObject(with: inserted) as! [String:Any]
let p = parsed["packages"] as! [[String:Any]]
precondition(p.count == 2 && p[1]["name"] as? String == "其它" && p[0]["unknown"] != nil)
precondition(p[0]["author"] as? String == "甲" && p[0]["section"] as? String == "自定义")
precondition(p[0]["name"] as? String == "引号\"和换行\n")
print("PASS text-preserving metadata fixture, root member selection and escaped string values")
