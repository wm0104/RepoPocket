import Foundation
@main struct Test {
    static func main() throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let out=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let changes=DebControlEditor.Changes(package:"new.test",version:"2:3.4-1",description:"New summary\ncontinued\n.\nlast",maintainer:"New <new@example.org>",optionalFields:["Section":"Tweaks", "Name":"新名称", "Author":"New Author"])
        for name in ["plain","gzip","xz","zst"] {
            let original=base.appendingPathComponent(name+".deb")
            let before=try Data(contentsOf:original)
            let result=out.appendingPathComponent(name+"-edited.deb")
            try DebControlEditor.edit(input:original,output:result,changes:changes)
            let after=try Data(contentsOf:original)
            precondition(after==before)
            do {try DebControlEditor.edit(input:original,output:result,changes:changes);fatalError("clobber accepted")}
            catch DebControlEditor.Failure.invalid(_) {print("PASS no clobber",name)}
            print("PASS edited",name)
        }
        for name in ["symlink","corrupt","truncated"] {
            let output=out.appendingPathComponent(name+"-edited.deb")
            do {try DebControlEditor.edit(input:base.appendingPathComponent(name+".deb"),output:output,changes:changes);fatalError("unsafe deb accepted: \(name)")}
            catch DebControlEditor.Failure.invalid(_) {
                precondition(!FileManager.default.fileExists(atPath:output.path));print("PASS rejected",name)
            }
        }
        for name in ["plain", "gzip", "xz", "zst"] {
            let input = base.appendingPathComponent("zero-" + name + ".deb")
            let output = out.appendingPathComponent("zero-" + name + "-repaired.deb")
            let before = try Data(contentsOf: input)
            let changed = try DebControlEditor.repairPermissions(input: input, output: output)
            precondition(changed)
            let again = out.appendingPathComponent("zero-" + name + "-again.deb")
            let repeated = try DebControlEditor.repairPermissions(input: output, output: again)
            precondition(!repeated && !FileManager.default.fileExists(atPath: again.path))
            let after = try Data(contentsOf: input); precondition(before == after)
            try DebControlEditor.edit(input: input, output: out.appendingPathComponent("zero-" + name + "-edited.deb"), changes: changes)
            print("PASS repair/edit zero permissions, idempotence", name)
        }
        for name in ["plain", "gzip", "xz", "zst", "nonzero"] {
            let result = out.appendingPathComponent(name + "-unneeded.deb")
            let changed = try DebControlEditor.repairPermissions(input: base.appendingPathComponent(name + ".deb"), output: result)
            precondition(!changed && !FileManager.default.fileExists(atPath: result.path))
        }
        for name in ["mode", "directory", "special", "symlink", "corrupt", "truncated"] {
            let result = out.appendingPathComponent(name + "-repair.deb")
            do { _ = try DebControlEditor.repairPermissions(input: base.appendingPathComponent(name + ".deb"), output: result); fatalError("unsafe repair accepted: " + name) }
            catch DebControlEditor.Failure.invalid(_) { precondition(!FileManager.default.fileExists(atPath: result.path)); print("PASS repair rejected", name) }
        }
        let unsupported = base.appendingPathComponent("unsupported.deb")
        let unverified = try DebControlEditor.prepareForUpload(unsupported)
        precondition(unverified.file == unsupported && unverified.notice?.contains("未修复") == true)
        let directory = out.appendingPathComponent("not-regular.deb")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { _ = try DebControlEditor.repairPermissions(input: directory, output: out.appendingPathComponent("bad.deb")); fatalError("directory accepted") }
        catch DebControlEditor.Failure.invalid(_) { print("PASS nonregular rejected") }
        let injection=DebControlEditor.Changes(package:"evil\nDepends: yes",version:"1",description:"ok",maintainer:"ok")
        do {try DebControlEditor.edit(input:base.appendingPathComponent("gzip.deb"),output:out.appendingPathComponent("injection.deb"),changes:injection);fatalError("injection accepted")}
        catch DebControlEditor.Failure.invalid(_) {print("PASS rejected injection")}
    }
}
