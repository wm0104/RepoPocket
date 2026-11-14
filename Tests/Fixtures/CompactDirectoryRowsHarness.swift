// Compiles the actual Entry and BrowserView comparator extracted by the host test.
func entry(_ name: String, _ path: String, _ type: String = "file") -> Entry {
    Entry(name: name, path: path, type: type, sha: "", size: nil,
          download_url: nil, content: nil, encoding: nil)
}
let rows = [entry("file10", "root/file10"), entry("file2", "root/file2"),
            entry("z", "root/z", "dir"), entry("a", "root/a", "dir"),
            entry("same", "z/same"), entry("same", "a/same"),
            entry("b", "a/b"), entry("a", "z/a"),
            entry("README", "root/README"), entry("readme", "root/readme")]
let less = DirectoryRowSort.directoryEntryPrecedes
let sorted = rows.sorted(by: less)
assert(sorted.prefix(2).map(\.path) == ["root/a", "root/z"])
let files = sorted.filter { $0.type != "dir" }.map(\.path)
assert(files.firstIndex(of: "root/file2")! < files.firstIndex(of: "root/file10")!)
assert(files.firstIndex(of: "a/same")! < files.firstIndex(of: "z/same")!)
assert(files.firstIndex(of: "z/a")! < files.firstIndex(of: "a/b")!)
let caseTies = rows.filter { $0.name.lowercased() == "readme" }
assert(caseTies.sorted(by: less).map(\.path) == caseTies.reversed().sorted(by: less).map(\.path))
assert(rows.reversed().sorted(by: less).map(\.path) == sorted.map(\.path))
for a in rows {
    assert(!less(a, a))
    for b in rows {
        assert(!(less(a, b) && less(b, a)))
        for c in rows where less(a, b) && less(b, c) { assert(less(a, c)) }
    }
}
assert([Entry]().sorted(by: less).isEmpty)
print("PASS: actual directory comparator, numeric names, name vs path, ties and order laws")
