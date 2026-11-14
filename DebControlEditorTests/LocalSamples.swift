import Foundation
import CryptoKit
@main struct LocalSamples {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/rpp-private-inputs")
        var phoneVerified = false
        for dir in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for input in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let repairDir = URL(fileURLWithPath: "/tmp/rpp-private-repaired").appendingPathComponent(dir.lastPathComponent)
                try fm.createDirectory(at: repairDir, withIntermediateDirectories: true)
                let repaired = repairDir.appendingPathComponent(input.lastPathComponent)
                let changed = try DebControlEditor.repairPermissions(input: input, output: repaired)
                if changed {
                    let again = repairDir.appendingPathComponent("again.deb")
                    let repeated = try DebControlEditor.repairPermissions(input: repaired, output: again)
                    precondition(!repeated && !fm.fileExists(atPath: again.path))
                }
                print("PASS private production permission repair/idempotence", dir.lastPathComponent, changed)
                let fields = try DebControlEditor.fields(at: input)
                let targetDir = URL(fileURLWithPath: "/tmp/rpp-private-outputs").appendingPathComponent(dir.lastPathComponent)
                try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                let output = targetDir.appendingPathComponent(input.lastPathComponent)
                let original = try Data(contentsOf: input)
                let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
                if hash == "290fa1dfbad0620ec6ae814f9a9acdcdc2869c6b87a3a040fb3585362e36c685" {
                    phoneVerified = true
                    print("PASS exact phone-assistant attachment SHA256", hash)
                }
                let changes = DebControlEditor.Changes(package: fields["Package"]!, version: fields["Version"]!, description: fields["Description"]! + "\nRepoPocket local verification", maintainer: fields["Maintainer"]!)
                try DebControlEditor.edit(input: input, output: output, changes: changes)
                let checked = try DebControlEditor.fields(at: output)
                let after = try Data(contentsOf: input)
                precondition(after == original && checked["Description"] == changes.description)
                print("PASS production Swift engine local sample", dir.lastPathComponent)
            }
        }
        precondition(phoneVerified, "Required exact phone-assistant sample missing")
    }
}
