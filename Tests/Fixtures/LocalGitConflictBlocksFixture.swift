import Foundation

@main
struct LocalGitConflictBlocksFixture {
    static func main() throws {
        let prefix = "😀 untouched\r\n"
        let text = prefix + "<<<<<<< CURRENT\nours\r\n=======\ntheirs\r\n>>>>>>> INCOMING\ntrailing\n"
        let blocks = LocalGitConflictBlocks.parse(text)
        precondition(blocks.count == 1)
        precondition(blocks[0].ours == "ours\r\n" && blocks[0].theirs == "theirs\r\n")
        precondition(LocalGitConflictBlocks.applying(blocks[0], choice: "ours", to: text) == prefix + "ours\r\ntrailing\n")
        precondition(LocalGitConflictBlocks.applying(blocks[0], choice: "theirs", to: text) == prefix + "theirs\r\ntrailing\n")
        precondition(LocalGitConflictBlocks.applying(blocks[0], choice: "both", to: text) == prefix + "ours\r\ntheirs\r\ntrailing\n")
        precondition(LocalGitConflictBlocks.parse("<<<<<<< CURRENT\na\n=======\nb\n").isEmpty)
        let inactive = try JSONDecoder().decode(LocalGitConflictSession.self, from: Data(#"{"active":false}"#.utf8))
        precondition(!inactive.active && inactive.files == nil)
        print("PASS production Swift conflict blocks and inactive session decoding")
    }
}
