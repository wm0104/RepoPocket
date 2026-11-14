import Foundation

/// Text-preserving editor for trollpackages.json. JSONSerialization is used only
/// to validate and decode the selected object; the original bytes are edited in place.
enum TrollMetadata {
    static func matches(_ value: String, repo: String, branch: String, path: String) -> Bool {
        guard let url = URLComponents(string: value), let host = url.host?.lowercased(), let decoded = url.percentEncodedPath.removingPercentEncoding else { return false }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2, !decoded.contains("\\"), !decoded.split(separator: "/").contains("..") else { return false }
        if host == (parts[0] + ".github.io").lowercased() { return decoded == "/" + parts[1] + "/" + path }
        if host == "raw.githubusercontent.com" { return decoded == "/" + repo + "/" + branch + "/" + path }
        if host == "github.com" { return decoded == "/" + repo + "/raw/" + branch + "/" + path || decoded == "/" + repo + "/blob/" + branch + "/" + path }
        return false
    }
    static func url(repo: String, path: String) throws -> String {
        let parts = repo.split(separator: "/").map(String.init); guard parts.count == 2 else { throw AppError(text: "无效仓库") }
        var c = URLComponents(); c.scheme = "https"; c.host = parts[0] + ".github.io"; c.path = "/" + parts[1] + "/" + path
        guard let u = c.url else { throw AppError(text: "无效插件路径") }; return u.absoluteString
    }
    static func package(index: [String: Any], repo: String, branch: String, path: String) throws -> [String: Any]? {
        guard let packages = index["packages"] as? [[String: Any]] else { throw AppError(text: "索引缺少 packages 数组") }
        let found = packages.filter { ($0["dylib"] as? String).map { matches($0, repo: repo, branch: branch, path: path) } ?? false }
        guard found.count <= 1 else { throw AppError(text: "索引存在重复插件 URL，请先修复索引") }; return found.first
    }

    // MARK: byte-preserving update
    private static func ws(_ b: [UInt8], _ i: inout Int) { while i < b.count && (b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13) { i += 1 } }
    private static func stringEnd(_ b: [UInt8], _ start: Int) -> Int? { var i = start + 1; while i < b.count { if b[i] == 92 { i += 2; continue }; if b[i] == 34 { return i + 1 }; i += 1 }; return nil }
    private static func valueEnd(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start; guard i < b.count else { return nil }
        if b[i] == 34 { return stringEnd(b, i) }
        if b[i] == 123 || b[i] == 91 { let open = b[i], close: UInt8 = open == 123 ? 125 : 93; var depth = 0; while i < b.count { if b[i] == 34 { guard let e = stringEnd(b,i) else{return nil}; i=e; continue }; if b[i] == open { depth += 1 }; if b[i] == close { depth -= 1; i += 1; if depth == 0{return i}; continue }; i += 1 }; return nil }
        while i < b.count && ![44,93,125,32,9,10,13].contains(b[i]) { i += 1 }; return i
    }
    private static func objectMembers(_ b: [UInt8], _ start: Int, _ end: Int) -> [(String, Int, Int)]? {
        guard start < end, b[start] == 123, b[end-1] == 125 else { return nil }; var i=start+1; var out:[(String,Int,Int)] = []
        while true { ws(b,&i); if i == end-1 { return out }; guard i < end, b[i] == 34, let ke=stringEnd(b,i), let key=String(data:Data(b[i..<ke]),encoding:.utf8), let kd=try? JSONSerialization.jsonObject(with:Data(key.utf8), options: [.fragmentsAllowed]) as? String else{return nil}; i=ke; ws(b,&i); guard i<end,b[i]==58 else{return nil}; i += 1; ws(b,&i); let vs=i; guard let ve=valueEnd(b,i) else{return nil}; out.append((kd,vs,ve)); i=ve; ws(b,&i); if i<end && b[i]==44 {i += 1; continue}; if i==end-1{return out}; return nil }
    }
    private static func jsonString(_ value: String) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) }
    static func updating(raw: Data, repo: String, branch: String, path: String, fields: [String:String]) throws -> Data {
        guard !(fields["name"] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !(fields["version"] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, fields.keys.allSatisfy({["name","version","description","bundle","author"].contains($0)}) else { throw AppError(text:"名称、版本必填；不允许更改 URL 或未知字段") }
        let b=[UInt8](raw); guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String:Any], root["packages"] is [Any] else { throw AppError(text:"索引格式无效，未提交") }
        var i=0; ws(b,&i)
        guard let rootEnd=valueEnd(b,i), let members=objectMembers(b,i,rootEnd), members.filter({$0.0 == "packages"}).count == 1, let member=members.first(where:{$0.0 == "packages"}), b[member.1] == 91 else { throw AppError(text:"索引缺少唯一 packages 数组，未提交") }
        let arrayStart=member.1; let arrayEnd=member.2; i=arrayStart+1
        var matchesCount=0; var edits:[(Int,Int,Data)] = []
        while i < arrayEnd-1 { ws(b,&i); guard i<arrayEnd-1 else{break}; guard b[i]==123, let oe=valueEnd(b,i), let members=objectMembers(b,i,oe) else { throw AppError(text:"packages 条目无法安全编辑，未提交") }
            if let d=members.first(where:{$0.0=="dylib"}), let s=String(data:Data(b[d.1..<d.2]),encoding:.utf8), let dylib=try? JSONSerialization.jsonObject(with:Data(s.utf8), options: [.fragmentsAllowed]) as? String, matches(dylib,repo:repo,branch:branch,path:path) {
                matchesCount += 1
                for (key,value) in fields { if let m=members.first(where:{$0.0==key}), let replacement=try? jsonString(value) { edits.append((m.1,m.2,replacement)) } }
                if !members.contains(where:{$0.0=="section"}) { edits.append((oe-1,oe-1,Data(", \"section\": \"插件\"".utf8))) }
                for (key,value) in fields where !members.contains(where:{$0.0==key}) { if let replacement=try? jsonString(value) { edits.append((oe-1,oe-1,Data(", \"\(key)\": ".utf8) + replacement)) } }
            }; i=oe; ws(b,&i); if i<arrayEnd-1 && b[i]==44{i += 1}
        }
        guard matchesCount <= 1 else { throw AppError(text:"索引存在重复插件 URL，请先修复索引") }; guard matchesCount == 1 else { throw AppError(text:"未找到对应 dylib 条目，未提交") }
        var result=b; for e in edits.sorted(by:{$0.0>$1.0}) { result.replaceSubrange(e.0..<e.1, with:e.2) }; let out=Data(result)
        guard (try? JSONSerialization.jsonObject(with:out)) != nil else { throw AppError(text:"更新后索引无效，未提交") }; return out
    }
    static func updating(_ index: [String:Any], repo:String, branch:String, path:String, fields:[String:String]) throws -> Data { let raw=try JSONSerialization.data(withJSONObject:index); return try updating(raw:raw,repo:repo,branch:branch,path:path,fields:fields) }
}

struct TrollMetadataSnapshot { let binding: WorkspaceBinding; let index: [String: Any]; let rawIndex: Data; let indexSHA: String?; let dylibSHA: String; let path: String }
