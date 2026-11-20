"""Swift format fixtures and host-side contracts for repository file previews."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RULES = ROOT / 'RepoPocket/RepositoryFilePreviewRules.swift'
SURFACE = ROOT / 'RepoPocket/RepositoryFilePreview.swift'


class RepositoryFilePreviewRulesTests(unittest.TestCase):
    def test_media_and_source_use_separate_bounded_decoders(self):
        self.assertTrue(RULES.is_file(), 'Ordinary and historical previews need one shared format policy')
        rules = RULES.read_text(encoding='utf-8')
        self.assertIn('SourceTextRules.automaticallyLoads(filename: path, size: nil)', rules)
        self.assertIn('SourceTextRules.byteLimit', rules)
        surface = SURFACE.read_text(encoding='utf-8')
        for marker in ['Task.detached', 'imageTypeIdentifier(for: path, bytes: data)',
                       'imageCanvasFits(type: expectedType, bytes: data)',
                       'CGImageSourceCopyPropertiesAtIndex(source, 0', 'imageDimensionsFit(width: width, height: height)',
                       'CGImageSourceCreateThumbnailAtIndex(source, 0',
                       'kCGImageSourceCreateThumbnailWithTransform: true',
                       'kCGImageSourceThumbnailMaxPixelSize:', 'SourceCodeView(text: text, filename: path)']:
            self.assertIn(marker, surface)
        self.assertNotIn('UIImage(data:', surface)

    def test_pdf_view_does_not_opt_into_external_actions(self):
        self.assertTrue(SURFACE.is_file())
        surface = SURFACE.read_text(encoding='utf-8')
        for marker in ['PDFDocument(data: data)', 'usePageViewController(true', 'view.autoScales = true',
                       'removeAnnotation(annotation)', 'override func perform(_ action: PDFAction) {}',
                       'func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}',
                       'func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}']:
            self.assertIn(marker, surface)
        for marker in ['super.perform(action)', 'UIApplication.shared.open', 'openURL(', 'SafariView']:
            self.assertNotIn(marker, surface)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for production rule assertions')
    def test_production_rules(self):
        fixture = r'''
import Foundation

@main struct Fixture {
    static func main() throws {
        typealias Rules = RepositoryFilePreviewRules
        func text(_ bytes: Data, cut: Bool = false) throws -> (value: String, notice: String?, editableSHA: String?) {
            try Rules.text(bytes, truncated: cut, editableSHA: "blob")
        }
        func rejects(_ bytes: [UInt8], cut: Bool = false) {
            do { _ = try text(Data(bytes), cut: cut); preconditionFailure("invalid text accepted: \(bytes)") }
            catch { }
        }
        for path in ["doc/a.PNG", "a.JpEg", "a.jpg", "a.webP", "a.gif"] {
            precondition(Rules.media(for: path) == .image && Rules.canPreview(path: path))
            precondition(Rules.byteLimit(for: path) > SourceTextRules.byteLimit)
            precondition(Rules.byteLimit(for: path) <= 16 * 1024 * 1024)
        }
        precondition(Rules.media(for: "doc/file.PDF") == .pdf && Rules.canPreview(path: "doc/file.PDF"))
        precondition(Rules.byteLimit(for: "a.pdf") > SourceTextRules.byteLimit)
        precondition(Rules.byteLimit(for: "a.pdf") <= 16 * 1024 * 1024)
        for path in ["a.SVG", "README.md", "Makefile", "a.swift", "a.unknown"] {
            precondition(Rules.media(for: path) == nil && Rules.canPreview(path: path))
            precondition(Rules.byteLimit(for: path) == 1024 * 1024)
        }
        for path in ["a.heic", "a.zip", "a.sqlite", "a.MP3"] { precondition(!Rules.canPreview(path: path)) }
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0])
        for path in ["CydiaIcon.png", "a.jpg", "a.JPEG", "a.gif", "a.webp"] {
            precondition(Rules.imageTypeIdentifier(for: path, bytes: jpeg) == "public.jpeg", "JPEG content rejected for \(path)")
            precondition(Rules.imageTypeIdentifier(for: path, bytes: png) == "public.png")
            precondition(Rules.imageTypeIdentifier(for: path, bytes: Data("GIF89a".utf8)) == "com.compuserve.gif")
            precondition(Rules.imageTypeIdentifier(for: path, bytes: Data("RIFF1234WEBP".utf8)) == "org.webmproject.webp")
            precondition(Rules.imageTypeIdentifier(for: path, bytes: Data("%PDF-1.4".utf8)) == nil)
        }
        for path in ["a.svg", "a.pdf", "a.bin", "no-extension"] {
            precondition(Rules.imageTypeIdentifier(for: path, bytes: jpeg) == nil)
        }
        precondition(Rules.imageDimensionsFit(width: 8192, height: 4096))
        precondition(!Rules.imageDimensionsFit(width: 8193, height: 4096))
        precondition(!Rules.imageDimensionsFit(width: Int.max, height: Int.max))
        precondition(!Rules.imageDimensionsFit(width: 10, height: 0))
        let gif = Data("GIF89a".utf8)
        precondition(Rules.imageCanvasFits(type: "com.compuserve.gif", bytes: gif + Data([0x00, 0x20, 0x00, 0x10])))
        precondition(!Rules.imageCanvasFits(type: "com.compuserve.gif", bytes: gif + Data([0x01, 0x20, 0x00, 0x10])))
        let webp = Data("RIFF1234WEBPVP8X".utf8) + Data([10, 0, 0, 0, 2, 0, 0, 0])
        precondition(Rules.imageCanvasFits(type: "org.webmproject.webp", bytes: webp + Data([0xff, 0x1f, 0, 0xff, 0x0f, 0])))
        precondition(!Rules.imageCanvasFits(type: "org.webmproject.webp", bytes: webp + Data([0, 0x20, 0, 0xff, 0x0f, 0])))
        let lfs = Data("version https://git-lfs.github.com/spec/v1\noid sha256:0123\nsize 1000\n".utf8)
        precondition(Rules.imageTypeIdentifier(for: "a.gif", bytes: lfs) == nil)
        precondition(Rules.isPDF(Data("%PDF-1.4\n".utf8)) && !Rules.isPDF(lfs))

        let empty = try text(Data())
        precondition(empty.value == "" && empty.notice == nil && empty.editableSHA == "blob")
        let original = Data("中国🇨🇳\r\n".utf8)
        let utf8 = try text(original)
        precondition(original.elementsEqual(utf8.value.utf8) && utf8.notice == nil && utf8.editableSHA == "blob")
        let utf8BOM = Data([0xef, 0xbb, 0xbf, 0x41])
        let withBOM = try text(utf8BOM)
        precondition(withBOM.value == "A" || withBOM.value == "\u{feff}A")
        precondition(withBOM.editableSHA == nil || utf8BOM.elementsEqual(withBOM.value.utf8))
        let cutUTF8 = try text(Data([0x41, 0xf0, 0x9f, 0x98]), cut: true)
        precondition(cutUTF8.value == "A" && cutUTF8.notice != nil && cutUTF8.editableSHA == nil)
        let cutAtBoundary = try text(Data("a😀".utf8), cut: true)
        precondition(cutAtBoundary.value == "a😀" && cutAtBoundary.notice != nil && cutAtBoundary.editableSHA == nil)
        rejects([0x41, 0xf0, 0x9f, 0x98]); rejects([0x41, 0x80], cut: true)
        rejects([0xc0], cut: true); rejects([0x41, 0xe0, 0x80], cut: true)
        rejects([0x41, 0xed, 0xa0], cut: true); rejects([0x41, 0xf4, 0x90], cut: true)
        rejects([0xff, 0x41, 0xe4], cut: true); rejects([0x41, 0x00]); rejects([0xe9])
        let exact = try text(Data(repeating: 0x41, count: SourceTextRules.byteLimit))
        precondition(exact.value.utf8.count == SourceTextRules.byteLimit && exact.editableSHA == "blob")
        let large = try text(Data(repeating: 0x41, count: SourceTextRules.byteLimit + 1))
        precondition(large.value.utf8.count == SourceTextRules.byteLimit && large.notice != nil && large.editableSHA == nil)

        for (bom, encoding) in [([0xff, 0xfe], String.Encoding.utf16LittleEndian), ([0xfe, 0xff], .utf16BigEndian),
                                ([0xff, 0xfe, 0, 0], .utf32LittleEndian), ([0, 0, 0xfe, 0xff], .utf32BigEndian)] as [([UInt8], String.Encoding)] {
            let encoded = Data(bom) + "中文😀\r\n".data(using: encoding)!
            let decoded = try text(encoded)
            precondition(decoded.value == "中文😀\r\n" && decoded.notice != nil && decoded.editableSHA == nil)
        }
        let cutUTF16 = try text(Data([0xff, 0xfe, 0x41, 0x00, 0x3d, 0xd8]), cut: true)
        precondition(cutUTF16.value == "A" && cutUTF16.notice != nil && cutUTF16.editableSHA == nil)
        rejects([0xff, 0xfe, 0x00, 0xdc], cut: true)
        rejects([0xff, 0xfe, 0x3d, 0xd8]); rejects([0xfe, 0xff, 0x41]); rejects([0, 0, 0xfe, 0xff, 0, 0x11, 0, 0])
        rejects([0xfe, 0xff, 0, 0]); rejects([0xfe, 0xff, 0x00, 0x41, 0xd8, 0x3d, 0x41], cut: true)
        let expanded = Data([0xff, 0xfe]) + String(repeating: "中", count: SourceTextRules.byteLimit / 2 - 1).data(using: .utf16LittleEndian)!
        let limited = try text(expanded)
        precondition(limited.value.utf8.count <= SourceTextRules.byteLimit && limited.value.utf8.count > SourceTextRules.byteLimit - 4)
        precondition(limited.notice != nil && limited.editableSHA == nil)
        print("PASS repository file preview rules")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / 'Fixture.swift'
            main.write_text(fixture, encoding='utf-8')
            output = str(Path(directory) / 'preview-rules')
            subprocess.run(['swiftc', '-parse-as-library', str(ROOT / 'RepoPocket/SourceLexer.swift'),
                            str(RULES), str(main), '-o', output], check=True)
            subprocess.run([output], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
