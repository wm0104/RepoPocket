import Foundation
import CryptoKit
import Darwin
import zlib

/// Bounded, fail-closed editor for conventional Debian binary packages. No subprocesses.
/// Only control.tar and control's payload are rewritten; the source URL is never written.
public enum DebControlEditor {
    public struct Changes {
        public var package: String
        public var version: String
        public var description: String
        public var maintainer: String
        /// Only Name, Author, Section, Priority and Homepage may be additionally changed.
        public var optionalFields: [String: String]

        public init(package: String, version: String, description: String,
                    maintainer: String, optionalFields: [String: String] = [:]) {
            self.package = package; self.version = version
            self.description = description; self.maintainer = maintainer
            self.optionalFields = optionalFields
        }
    }

    public enum Failure: Error, LocalizedError {
        case invalid(String)
        case unsupported(String)
        public var errorDescription: String? {
            switch self { case .invalid(let message), .unsupported(let message): return message }
            return nil
        }
    }

    private static let maxDeb = 512 * 1024 * 1024
    private static let maxControlCompressed = 32 * 1024 * 1024
    private static let maxTar = 32 * 1024 * 1024
    private static let maxEntries = 256

    /// Write a NEW .deb, validate by reparsing and comparing SHA-256 of data.tar's exact bytes.
    /// Existing output files and identical input/output paths are refused.
    public static func edit(input: URL, output: URL, changes: Changes) throws {
        guard input.isFileURL, output.isFileURL,
              input.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else {
            throw Failure.invalid("Input and output must be different local files")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let length = attributes[.size] as? NSNumber, length.int64Value <= maxDeb else {
            throw Failure.invalid("Input is not a regular file or exceeds 512 MiB")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.invalid("Output already exists")
        }
        let source = try Data(contentsOf: input, options: .mappedIfSafe)
        guard source.count <= maxDeb else { throw Failure.invalid("Input changed or exceeds size limit") }
        let parsed = try parseAr(source)
        let member = parsed.members[parsed.control]
        let tar = try decodeControl(source.subdata(in: member.body), name: member.name)
        let replacementTar = try editTar(tar, changes: changes)
        let packed = try encodeControl(replacementTar, name: member.name)
        guard packed.count <= maxControlCompressed else { throw Failure.invalid("Compressed control exceeds limit") }
        // Canonical short name replaces GNU/BSD name indirection safely; retain metadata.
        var header = source.subdata(in: member.start..<member.start+60)
        let outputName = member.name == "control.tar" ? "control.tar" : "control.tar.gz"
        header.replaceSubrange(0..<16, with: (outputName + "/").padding(toLength: 16, withPad: " ", startingAt: 0).utf8)
        let sizeField = String(packed.count).padding(toLength: 10, withPad: " ", startingAt: 0)
        guard sizeField.utf8.count == 10 else { throw Failure.invalid("ar size overflow") }
        header.replaceSubrange(48..<58, with: sizeField.utf8)
        let newMember = header + packed + (packed.count % 2 == 1 ? Data([10]) : Data())
        var result = Data()
        result.append(source.subdata(in: 0..<member.start))
        result.append(newMember)
        result.append(source.subdata(in: member.end..<source.count))
        guard result.count <= maxDeb else { throw Failure.invalid("Output exceeds 512 MiB") }
        let check = try parseAr(result)
        let originalData = parsed.members[parsed.data]
        let checkedData = check.members[check.data]
        guard SHA256.hash(data: source.subdata(in: originalData.body)) == SHA256.hash(data: result.subdata(in: checkedData.body)),
              source.subdata(in: originalData.start..<originalData.end) == result.subdata(in: checkedData.start..<checkedData.end) else {
            throw Failure.invalid("data.tar changed")
        }
        guard check.members.count == parsed.members.count else { throw Failure.invalid("ar members changed") }
        for i in parsed.members.indices where i != parsed.control {
            let old = parsed.members[i], new = check.members[i]
            guard old.name == new.name, source.subdata(in: old.start..<old.end) == result.subdata(in: new.start..<new.end) else { throw Failure.invalid("Non-control member changed") }
        }
        let checkTar = try decodeControl(result.subdata(in: check.members[check.control].body), name: check.members[check.control].name)
        _ = try inspectTar(checkTar)
        guard checkTar == replacementTar else { throw Failure.invalid("Control verification failed") }
        // Atomic no-clobber creation: O_EXCL prevents races; remove partial result on any error.
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure.invalid("Cannot create output exclusively") }
        var completed = false
        defer { _ = close(fd); if !completed { try? FileManager.default.removeItem(at: output) } }
        try result.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw Failure.invalid("Empty package") }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                guard n > 0 else { throw Failure.invalid("Output write failed") }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw Failure.invalid("Output sync failed") }
        completed = true
    }

    /// Repair only safe standard control-file permissions. Data archive bytes and all
    /// non-control ar members remain byte-for-byte unchanged. A new file is created.
    public static func repairPermissions(input: URL, output: URL) throws -> Bool {
        guard input.isFileURL, output.isFileURL,
              input.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: output.path) else { throw Failure.invalid("无效的 deb 修复输入或输出") }
        let attrs = try FileManager.default.attributesOfItem(atPath: input.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value >= 0, size.int64Value <= maxDeb else {
            throw Failure.invalid("Input is not a regular file or exceeds 512 MiB")
        }
        let source = try Data(contentsOf: input, options: .mappedIfSafe)
        guard source.count <= maxDeb else { throw Failure.invalid("Input changed or exceeds size limit") }
        let parsed = try parseAr(source)
        let member = parsed.members[parsed.control]
        let tar = try decodeControl(source.subdata(in: member.body), name: member.name)
        let repaired = try repairTarPermissions(tar)
        guard repaired != tar else { return false }
        let packed = try encodeControl(repaired, name: member.name)
        guard packed.count <= maxControlCompressed else { throw Failure.invalid("Compressed control exceeds limit") }
        var header = source.subdata(in: member.start..<member.start + 60)
        let outputName = member.name == "control.tar" ? "control.tar" : "control.tar.gz"
        header.replaceSubrange(0..<16, with: (outputName + "/").padding(toLength: 16, withPad: " ", startingAt: 0).utf8)
        let sizeField = String(packed.count).padding(toLength: 10, withPad: " ", startingAt: 0)
        guard sizeField.utf8.count == 10 else { throw Failure.invalid("ar size overflow") }
        header.replaceSubrange(48..<58, with: sizeField.utf8)
        var result = Data(); result.append(source.prefix(member.start)); result.append(header); result.append(packed)
        if packed.count & 1 == 1 { result.append(10) }
        result.append(source.subdata(in: member.end..<source.count))
        guard result.count <= maxDeb else { throw Failure.invalid("Output exceeds 512 MiB") }
        let checked = try parseAr(result)
        let oldData = parsed.members[parsed.data]
        let newData = checked.members[checked.data]
        guard source.subdata(in: oldData.start..<oldData.end) == result.subdata(in: newData.start..<newData.end) else { throw Failure.invalid("data.tar 被意外修改") }
        guard checked.members.count == parsed.members.count else { throw Failure.invalid("ar members changed") }
        for i in parsed.members.indices where i != parsed.control {
            let old = parsed.members[i], new = checked.members[i]
            guard old.name == new.name, source.subdata(in: old.start..<old.end) == result.subdata(in: new.start..<new.end) else { throw Failure.invalid("Non-control member changed") }
        }
        let control = checked.members[checked.control]
        let verified = try decodeControl(result.subdata(in: control.body), name: control.name)
        _ = try inspectTar(verified)
        guard verified == repaired else { throw Failure.invalid("Control verification failed") }
        try result.write(to: output, options: .withoutOverwriting)
        return true
    }

    /// Operates only on an app-owned staging copy; never modifies the source.
    /// Unsupported compression is explicitly unverified, never reported repaired.
    public static func prepareForUpload(_ input: URL) throws -> (file: URL, notice: String?) {
        guard input.pathExtension.lowercased() == "deb" else { return (input, nil) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent(input.lastPathComponent)
        do {
            if try repairPermissions(input: input, output: output) { return (output, "已安全修复 deb 标准 control 文件的 0000 权限；data 保持不变。") }
            try? FileManager.default.removeItem(at: dir)
            return (input, nil)
        } catch Failure.unsupported(_) {
            try? FileManager.default.removeItem(at: dir)
            return (input, "此 deb 的 control 压缩格式不支持权限检查，保持原样上传；未验证、未修复。")
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private static func repairTarPermissions(_ tar: Data) throws -> Data {
        let inspected = try inspectTar(tar)
        var result = tar
        let scripts = ["preinst", "postinst", "prerm", "postrm", "config"]
        for item in inspected.entries {
            let type = tar[item.header + 156]
            let standard = item.name == "control" || scripts.contains(item.name)
            if standard && type == 53 { throw Failure.invalid("Standard control file is a directory: " + item.name) }
            // Preserve every valid nonzero mode, including custom files and directories.
            // Reject special permissions on standard files rather than silently stripping them.
            if standard && item.mode & 0o7000 != 0 { throw Failure.invalid("Unsafe special permissions: " + item.name) }
            let wanted: Int
            if item.name.isEmpty && type == 53 { wanted = 0o755 }
            else if item.name == "control" { wanted = 0o644 }
            else if scripts.contains(item.name) { wanted = 0o755 }
            else { continue }
            guard item.mode == 0 else { continue }
            var header = result.subdata(in: item.header..<item.header + 512)
            let digits = String(wanted, radix: 8)
            header.replaceSubrange(100..<108, with: (String(repeating: "0", count: 7 - digits.count) + digits + "\0").utf8)
            header.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
            let sum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
            header.replaceSubrange(148..<156, with: (String(repeating: "0", count: 7 - sum.count) + sum + "\0").utf8)
            result.replaceSubrange(item.header..<item.header + 512, with: header)
        }
        _ = try inspectTar(result)
        return result
    }

    /// Inspection shares every archive, compression, tar and field validation with editing.
    public static func fields(at file: URL) throws -> [String: String] {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value <= maxDeb else {
            throw Failure.invalid("Input is not a regular file or exceeds limit")
        }
        let raw = try Data(contentsOf: file, options: .mappedIfSafe)
        guard raw.count <= maxDeb else { throw Failure.invalid("Input exceeds limit") }
        let ar = try parseAr(raw); let member = ar.members[ar.control]
        let tar = try decodeControl(raw.subdata(in: member.body), name: member.name)
        let inspected = try inspectTar(tar)
        let bytes = tar.subdata(in: inspected.entries[inspected.control].payload)
        guard bytes.count <= 1024 * 1024, let text = String(data: bytes, encoding: .utf8) else { throw Failure.invalid("Invalid control text") }
        var fields = [String: String](), key = ""
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !key.isEmpty else { throw Failure.invalid("Orphan continuation") }
                fields[key, default: ""] += "\n" + String(line.dropFirst())
            } else {
                guard let colon = line.firstIndex(of: ":") else { throw Failure.invalid("Malformed field") }
                key = String(line[..<colon]); fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let changes = Changes(package: fields["Package"] ?? "", version: fields["Version"] ?? "", description: fields["Description"] ?? "", maintainer: fields["Maintainer"] ?? "")
        _ = try editFields(text, changes: changes)
        return fields
    }

    private struct Member {
        let name: String
        let start: Int
        let body: Range<Int>
        let end: Int
    }
    private struct Archive {
        let members: [Member]
        let control: Int
        let data: Int
    }
    private static func ascii(_ bytes: Data) -> String? {
        guard bytes.allSatisfy({ $0 < 128 }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
    private static func decimal(_ bytes: Data) -> Int? {
        guard let s = ascii(bytes)?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              s.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(s)
    }
    private static func parseAr(_ raw: Data) throws -> Archive {
        guard raw.count >= 8, raw.prefix(8) == Data("!<arch>\n".utf8) else { throw Failure.invalid("Not a Debian ar archive") }
        var cursor = 8, members = [Member](), gnu: Data?
        while cursor < raw.count {
            guard members.count < maxEntries, raw.count - cursor >= 60,
                  raw.subdata(in: cursor+58..<cursor+60) == Data("`\n".utf8),
                  let size = decimal(raw.subdata(in: cursor+48..<cursor+58)),
                  size <= raw.count - cursor - 60 else { throw Failure.invalid("Invalid ar member header") }
            let start = cursor, bodyStart = cursor + 60, bodyEnd = bodyStart + size
            guard let rawName = ascii(raw.subdata(in: cursor..<cursor+16))?.trimmingCharacters(in: .whitespaces),
                  !rawName.isEmpty else { throw Failure.invalid("Invalid ar name") }
            var name = rawName
            var payload = bodyStart..<bodyEnd
            if rawName == "//" {
                guard gnu == nil, size <= maxControlCompressed else { throw Failure.invalid("Invalid GNU name table") }
                gnu = raw.subdata(in: payload)
            } else if rawName.hasPrefix("#1/") {
                guard let n = Int(rawName.dropFirst(3)), n > 0, n <= 256, n <= size,
                      let decoded = ascii(raw.subdata(in: bodyStart..<bodyStart+n)) else { throw Failure.invalid("Invalid BSD ar name") }
                name = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                payload = bodyStart+n..<bodyEnd
            } else if rawName.hasPrefix("/"), rawName != "/" {
                guard let offset = Int(rawName.dropFirst()), let table = gnu,
                      offset >= 0, offset < table.count,
                      let newline = table[offset...].firstIndex(of: 10), newline - offset <= 256,
                      let decoded = ascii(table.subdata(in: offset..<newline)) else { throw Failure.invalid("Invalid GNU ar name reference") }
                name = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
            } else if name.hasSuffix("/") { name.removeLast() }
            guard name == "/" || name == "//" || (!name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("\0")) else {
                throw Failure.invalid("Unsafe ar member name")
            }
            let end = bodyEnd + (size & 1)
            guard end <= raw.count, size & 1 == 0 || raw[bodyEnd] == 10 else { throw Failure.invalid("Invalid ar padding") }
            members.append(Member(name: name, start: start, body: payload, end: end))
            cursor = end
        }
        guard cursor == raw.count, members.count >= 3,
              members[0].name == "debian-binary", raw.subdata(in: members[0].body) == Data("2.0\n".utf8) else {
            throw Failure.invalid("Invalid debian-binary member")
        }
        let controls = members.indices.filter { members[$0].name == "control.tar" || members[$0].name.hasPrefix("control.tar.") }
        let datas = members.indices.filter { members[$0].name == "data.tar" || members[$0].name.hasPrefix("data.tar.") }
        guard controls.count == 1, datas.count == 1, controls[0] < datas[0],
              members[controls[0]].body.count <= maxControlCompressed,
              Set(members.map(\.name)).count == members.count else { throw Failure.invalid("Ambiguous or oversized deb members") }
        return Archive(members: members, control: controls[0], data: datas[0])
    }

    private static func decodeControl(_ payload: Data, name: String) throws -> Data {
        if name == "control.tar" {
            guard payload.count <= maxTar else { throw Failure.invalid("control.tar too large") }
            return payload
        }
        if name == "control.tar.xz" || name == "control.tar.zst" {
            var result = Data(count: maxTar)
            var written = 0
            let status = payload.withUnsafeBytes { src in
                result.withUnsafeMutableBytes { dst in
                    rpp_decode(name == "control.tar.xz" ? 1 : 2, src.baseAddress, payload.count, dst.baseAddress, maxTar, &written)
                }
            }
            guard status == 0, written <= maxTar else { throw Failure.invalid("Invalid, unsupported or oversized compressed control stream") }
            result.removeSubrange(written..<result.count)
            return result
        }
        guard name == "control.tar.gz" else {
            throw Failure.unsupported("Unsupported control compression \(name); supported: plain, gzip, xz, zstd")
        }
        return try gzip(payload, decompress: true)
    }
    private static func encodeControl(_ tar: Data, name: String) throws -> Data {
        if name == "control.tar" { return tar }
        return try gzip(tar, decompress: false)
    }
    private static func gzip(_ input: Data, decompress: Bool) throws -> Data {
        var stream = z_stream()
        let initialized = decompress
            ? inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw Failure.invalid("Cannot initialize gzip codec") }
        defer { if decompress { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        var result = Data()
        try input.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw Failure.invalid("Empty gzip data") }
            guard raw.count <= Int(UInt32.max) else { throw Failure.invalid("gzip input too large") }
            stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(raw.count)
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let status = chunk.withUnsafeMutableBytes { ptr -> Int32 in
                    stream.next_out = ptr.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(ptr.count)
                    return decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw Failure.invalid("Malformed gzip stream") }
                let written = chunk.count - Int(stream.avail_out)
                let limit = decompress ? maxTar : maxControlCompressed
                guard written <= limit - result.count else { throw Failure.invalid("gzip output exceeds limit") }
                result.append(contentsOf: chunk.prefix(written))
                if status == Z_STREAM_END { break }
                guard written > 0 else { throw Failure.invalid("Truncated gzip stream") }
            }
            guard stream.avail_in == 0 else { throw Failure.invalid("Trailing gzip bytes") }
        }
        return result
    }

    private struct TarEntry {
        let name: String
        let header: Int
        let payload: Range<Int>
        let end: Int
        let mode: Int
    }
    private static func octal(_ bytes: Data) -> Int? {
        guard bytes.allSatisfy({ $0 < 128 }), let string = ascii(bytes) else { return nil }
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...55).contains($0) }) else { return nil }
        return Int(trimmed, radix: 8)
    }
    private static func nulString(_ bytes: Data) -> String? {
        let b = bytes.prefix { $0 != 0 }
        guard let text = String(bytes: b, encoding: .utf8), !text.contains("\0"),
              bytes.dropFirst(b.count).allSatisfy({ $0 == 0 }) else { return nil }
        return text
    }
    private static func inspectTar(_ tar: Data) throws -> (entries: [TarEntry], control: Int) {
        guard tar.count <= maxTar, tar.count % 512 == 0 else { throw Failure.invalid("Invalid control tar size") }
        var cursor = 0, entries = [TarEntry](), names = Set<String>(), zero = false
        while cursor < tar.count {
            let header = tar.subdata(in: cursor..<cursor+512)
            if header.allSatisfy({ $0 == 0 }) { zero = true; break }
            guard entries.count < maxEntries,
                  let stored = octal(header.subdata(in: 148..<156)) else { throw Failure.invalid("Malformed tar header") }
            var sum = 0
            for i in 0..<512 { sum += (148..<156).contains(i) ? 32 : Int(header[i]) }
            let posix = header.subdata(in: 257..<265) == Data([117, 115, 116, 97, 114, 0, 48, 48])
            let gnu = header.subdata(in: 257..<265) == Data("ustar  \0".utf8)
            guard stored == sum, posix || gnu,
                  !gnu || header.subdata(in: 345..<512).allSatisfy({ $0 == 0 }),
                  let base = nulString(header.subdata(in: 0..<100)),
                  let prefix = nulString(header.subdata(in: 345..<500)),
                  let length = octal(header.subdata(in: 124..<136)),
                  let mode = octal(header.subdata(in: 100..<108)), mode <= 0o7777,
                  !base.isEmpty, length <= maxTar else { throw Failure.invalid("Invalid tar metadata or checksum") }
            let name = prefix.isEmpty ? base : prefix + "/" + base
            let pieces = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !pieces.contains(".."), !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  !header.subdata(in: 157..<257).contains(where: { $0 != 0 }) else {
                throw Failure.invalid("Unsafe tar path or link")
            }
            let canonical = pieces.filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
            let type = header[156]
            guard (!canonical.isEmpty || (type == 53 && (name == "./" || name == "."))),
                  names.insert(canonical.isEmpty ? "." : canonical).inserted else { throw Failure.invalid("Duplicate tar entry") }
            guard type == 48 || type == 0 || type == 53,
                  type != 53 || length == 0 else { throw Failure.invalid("Unsupported tar entry type") }
            let body = cursor + 512
            let padded = ((length + 511) / 512) * 512
            guard padded <= tar.count - body else { throw Failure.invalid("Truncated tar payload") }
            let end = body + padded
            guard tar.subdata(in: body+length..<end).allSatisfy({ $0 == 0 }) else { throw Failure.invalid("Nonzero tar padding") }
            entries.append(TarEntry(name: canonical, header: cursor, payload: body..<body+length, end: end, mode: mode))
            cursor = end
        }
        guard zero, tar.count - cursor >= 1024,
              tar.subdata(in: cursor..<tar.count).allSatisfy({ $0 == 0 }),
              let index = entries.firstIndex(where: { $0.name == "control" }),
              tar[entries[index].header + 156] == 48 || tar[entries[index].header + 156] == 0 else {
            throw Failure.invalid("Missing regular control file or tar terminator")
        }
        return (entries, index)
    }
    private static func editTar(_ tar: Data, changes: Changes) throws -> Data {
        let inspected = try inspectTar(tar)
        let entry = inspected.entries[inspected.control]
        let original = tar.subdata(in: entry.payload)
        guard original.count <= 1024 * 1024, let text = String(data: original, encoding: .utf8) else {
            throw Failure.invalid("Control text is not bounded UTF-8")
        }
        let updated = try editFields(text, changes: changes)
        let newData = Data(updated.utf8)
        guard newData.count <= 1024 * 1024 else { throw Failure.invalid("Control text exceeds 1 MiB") }
        var header = tar.subdata(in: entry.header..<entry.header+512)
        func setOctal(_ number: Int, at offset: Int, width: Int) throws {
            let digits = String(number, radix: 8)
            guard digits.count <= width - 1 else { throw Failure.invalid("tar field overflow") }
            let field = String(repeating: "0", count: width - 1 - digits.count) + digits + "\0"
            header.replaceSubrange(offset..<offset+width, with: field.utf8)
        }
        try setOctal(newData.count, at: 124, width: 12)
        header.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
        try setOctal(header.reduce(0) { $0 + Int($1) }, at: 148, width: 8)
        var output = Data()
        output.append(tar.prefix(entry.header))
        output.append(header)
        output.append(newData)
        output.append(contentsOf: repeatElement(UInt8(0), count: (512 - newData.count % 512) % 512))
        output.append(tar.suffix(from: entry.end))
        return try repairTarPermissions(output)
    }

    private static func editFields(_ text: String, changes: Changes) throws -> String {
        let replacements = ["Package": changes.package, "Version": changes.version,
                            "Description": changes.description, "Maintainer": changes.maintainer]
            .merging(changes.optionalFields) { current, _ in current }
        guard changes.optionalFields.keys.allSatisfy({ ["Name", "Author", "Section", "Priority", "Homepage"].contains($0) }),
              !text.contains("\r"), text.hasSuffix("\n"), !text.contains("\0") else {
            throw Failure.invalid("Invalid control fields or newline encoding")
        }
        for (key, value) in replacements {
            guard !value.isEmpty, value.utf8.count <= 65536, !value.contains("\r"), !value.contains("\0"),
                  value.unicodeScalars.allSatisfy({ $0.value >= 32 || $0.value == 10 }),
                  (key == "Description" || !value.contains("\n")) else { throw Failure.invalid("Unsafe \(key) value") }
        }
        guard changes.package.range(of: "^[a-z0-9][a-z0-9+.-]*$", options: .regularExpression) != nil,
              changes.version.range(of: "^[0-9][A-Za-z0-9.+:~\\-]*$", options: .regularExpression) != nil,
              !changes.description.hasPrefix("\n"), !changes.description.hasSuffix("\n"),
              changes.description.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else {
            throw Failure.invalid("Invalid Package, Version or Description")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Debian control may end with blank separator lines, but must contain only one paragraph.
        while lines.last == "" { lines.removeLast() }
        var blocks = [(String, [String])](), currentName: String?
        for line in lines {
            if line.isEmpty { throw Failure.invalid("Multiple control paragraphs not supported") }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard currentName != nil else { throw Failure.invalid("Orphan continuation") }
                blocks[blocks.count - 1].1.append(line)
            } else {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw Failure.invalid("Malformed control line") }
                let key = String(line[..<colon])
                guard key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                      !blocks.contains(where: { $0.0.lowercased() == key.lowercased() }),
                      line[line.index(after: colon)...].first == " " else { throw Failure.invalid("Invalid or duplicate control field") }
                blocks.append((key, [line])); currentName = key
            }
        }
        for required in ["Package", "Version", "Description", "Maintainer"] {
            guard blocks.contains(where: { $0.0.lowercased() == required.lowercased() }) else { throw Failure.invalid("Missing \(required) field") }
        }
        for (field, value) in replacements {
            let first: String
            var continuation = [String]()
            if field == "Description" {
                let pieces = value.components(separatedBy: "\n")
                first = pieces[0]
                continuation = pieces.dropFirst().map { $0 == "." ? " ." : " " + $0 }
            } else { first = value }
            let idx = blocks.firstIndex { $0.0.lowercased() == field.lowercased() }
            if let idx = idx { blocks[idx].1 = [blocks[idx].0 + ": " + first] + continuation }
            else { blocks.append((field, [field + ": " + first] + continuation)) }
        }
        return blocks.flatMap { $0.1 }.joined(separator: "\n") + "\n"
    }
}
