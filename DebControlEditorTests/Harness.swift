import Foundation
@main struct Test {
    static func main() throws {
        // Regression cases exercise the same field implementation as archive editing.
        precondition(DebControlEditor.validReleaseDate("2024-02-29"))
        for date in ["2023-02-29", "2026-04-31", "2026-1-01", "", "2026-11-12\n"] {
            precondition(!DebControlEditor.validReleaseDate(date))
        }
        let logKey = "X-WM0104-Changelog", dateKey = "X-WM0104-Release-Date"
        var metadata = ["Package": "com.wm0104.repopocket", "Version": "1.0",
                        "X-RepoPocket-Changelog": "1.0 | 2024-02-29 | Old；Second"]
        var loaded = DebControlEditor.releaseInformation(fields: metadata)
        precondition(loaded.date == "2024-02-29" && loaded.changelog == "Old\nSecond")
        metadata[logKey] = "1.0 | 2025-01-01 | Unified"
        metadata[dateKey] = "2026-11-12"
        loaded = DebControlEditor.releaseInformation(fields: metadata)
        precondition(loaded.date == "2026-11-12" && loaded.changelog == "Unified")
        metadata["Version"] = "2.0"; metadata[dateKey] = nil
        loaded = DebControlEditor.releaseInformation(fields: metadata, now: Date(timeIntervalSince1970: 0))
        let today = DateFormatter(); today.locale = Locale(identifier: "en_US_POSIX")
        today.calendar = Calendar(identifier: .gregorian); today.timeZone = .current; today.dateFormat = "yyyy-MM-dd"
        precondition(loaded.date == today.string(from: Date(timeIntervalSince1970: 0)) && loaded.changelog.isEmpty)
        let moved = try DebControlEditor.releaseFields(package: "other.test", originalPackage: "com.wm0104.repopocket", version: "2.0", date: "2026-11-12", changelog: "Old\nSecond")
        precondition(moved[logKey] == "2.0 | 2026-11-12 | Old；Second" && moved["X-RepoPocket-Changelog"] == "")
        let cleared = try DebControlEditor.releaseFields(package: "other.test", originalPackage: "other.test", version: "2", date: "2026-11-12", changelog: "  \n")
        precondition(cleared[logKey] == "" && cleared[dateKey] == "2026-11-12" && cleared["X-RepoPocket-Changelog"] == nil)
        metadata = ["Package": "other.test", "Version": "1.0", "X-RepoPocket-Changelog": "1.0 | 2024-02-29 | Ignore"]
        precondition(DebControlEditor.releaseInformation(fields: metadata).changelog.isEmpty)
        for bad in ["a；b", "a | b", "bad\rvalue", "bad\u{7f}"] {
            do { _ = try DebControlEditor.releaseFields(package: "other.test", originalPackage: "other.test", version: "2", date: "2026-11-12", changelog: bad); fatalError("invalid log accepted") }
            catch DebControlEditor.Failure.invalid(_) {}
        }
        let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let out=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let changes=DebControlEditor.Changes(package:"new.test",version:"2:3.4-1",description:"New summary\ncontinued\n\nlast",maintainer:"New <new@example.org>",optionalFields:["Section":"Tweaks", "Name":"新名称", "Author":"New Author"])
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
        let input = base.appendingPathComponent("plain.deb")
        let originalFields = try DebControlEditor.fields(at: input)
        precondition(originalFields["Description"] == "Old summary\nsecond line\n\nlast")
        let dated = DebControlEditor.Changes(package: "old.test", version: "2.0", description: originalFields["Description"]!, maintainer: originalFields["Maintainer"]!, releaseDate: "2024-02-29", changelog: "One\nTwo")
        let datedURL = out.appendingPathComponent("dated.deb")
        try DebControlEditor.edit(input: input, output: datedURL, changes: dated)
        let reread = try DebControlEditor.fields(at: datedURL)
        precondition(reread[logKey] == "2.0 | 2024-02-29 | One；Two" && reread[dateKey] == "2024-02-29")
        precondition(reread["Description"] == originalFields["Description"] && reread["Depends"] == originalFields["Depends"])
        var empty = dated; empty.changelog = ""; empty.version = "3.0"
        let clearedURL = out.appendingPathComponent("cleared.deb")
        try DebControlEditor.edit(input: datedURL, output: clearedURL, changes: empty)
        let clearedFields = try DebControlEditor.fields(at: clearedURL)
        precondition(clearedFields[logKey] == nil && clearedFields[dateKey] == "2024-02-29")
        let unchanged = DebControlEditor.Changes(package: originalFields["Package"]!, version: originalFields["Version"]!, description: originalFields["Description"]!, maintainer: originalFields["Maintainer"]!)
        let unchangedURL = out.appendingPathComponent("unchanged.deb")
        try DebControlEditor.edit(input: input, output: unchangedURL, changes: unchanged)
        let unchangedBytes = try Data(contentsOf: unchangedURL)
        let inputBytes = try Data(contentsOf: input)
        precondition(inputBytes == unchangedBytes)
        for name in ["legacy", "unified", "foreign"] {
            let source = base.appendingPathComponent(name + ".deb")
            let fields = try DebControlEditor.fields(at: source)
            let before = try Data(contentsOf: source)
            let release = DebControlEditor.releaseInformation(fields: fields)
            if name == "legacy" { precondition(release.changelog == "**更新**\nSecond") }
            if name == "unified" { precondition(release.changelog == "Unified") }
            if name == "foreign" { precondition(release.changelog.isEmpty) }
            var change = DebControlEditor.Changes(package: fields["Package"]!, version: "2.0", description: fields["Description"]!, maintainer: fields["Maintainer"]!, releaseDate: "2026-11-12", changelog: "**更新**\nSecond")
            let saved = out.appendingPathComponent(name + "-metadata.deb")
            try DebControlEditor.edit(input: source, output: saved, changes: change)
            let savedFields = try DebControlEditor.fields(at: saved)
            precondition(savedFields[logKey] == "2.0 | 2026-11-12 | **更新**；Second")
            precondition(DebControlEditor.releaseInformation(fields: savedFields).changelog == "**更新**\nSecond")
            precondition(savedFields["X-Unknown"] == fields["X-Unknown"])
            if name == "foreign" { precondition(savedFields["X-RepoPocket-Changelog"] == fields["X-RepoPocket-Changelog"]) }
            else { precondition(savedFields["X-RepoPocket-Changelog"] == nil) }
            change.changelog = ""
            let cleared = out.appendingPathComponent(name + "-cleared.deb")
            try DebControlEditor.edit(input: source, output: cleared, changes: change)
            let clearedFields = try DebControlEditor.fields(at: cleared)
            precondition(clearedFields[logKey] == nil && clearedFields[dateKey] == "2026-11-12")
            precondition(DebControlEditor.releaseInformation(fields: clearedFields).changelog.isEmpty)
            let after = try Data(contentsOf: source); precondition(before == after)
        }
        var invalid = dated; invalid.releaseDate = "2023-02-29"
        do { try DebControlEditor.edit(input: input, output: out.appendingPathComponent("invalid-date.deb"), changes: invalid); fatalError("invalid date saved") }
        catch DebControlEditor.Failure.invalid(_) {}
        for bad in ["Summary\n.", "Summary\n   ", "\nSummary"] {
            invalid = dated; invalid.description = bad
            do { try DebControlEditor.edit(input: input, output: out.appendingPathComponent("invalid-description.deb"), changes: invalid); fatalError("invalid description saved") }
            catch DebControlEditor.Failure.invalid(_) {}
        }
        print("PASS release metadata, Markdown, description and no-op regression cases")
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
