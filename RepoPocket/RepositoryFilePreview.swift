import ImageIO
import PDFKit
import SwiftUI

// The worker finishes all mutations before handing its result to the UI; the
// PDFDocument is thereafter used only by the preview on the main actor.
enum RepositoryFilePreview: @unchecked Sendable {
    case text(String, notice: String?, editableSHA: String?)
    case image(CGImage)
    case pdf(PDFDocument)

    static func decode(_ data: Data, path: String, truncated: Bool, editableSHA: String?) async throws -> RepositoryFilePreview {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let preview = try Self.decodeContent(data, path: path, truncated: truncated, editableSHA: editableSHA)
            try Task.checkCancellation()
            return preview
        }
        let preview = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        return preview
    }

    private static func decodeContent(_ data: Data, path: String, truncated: Bool, editableSHA: String?) throws -> RepositoryFilePreview {
        typealias Rules = RepositoryFilePreviewRules
        guard Rules.canPreview(path: path) else { throw AppError(text: "此格式请下载后使用对应应用打开。") }
        guard let media = Rules.media(for: path) else {
            let text = try Rules.text(data, truncated: truncated, editableSHA: editableSHA)
            return .text(text.value, notice: text.notice, editableSHA: text.editableSHA)
        }
        guard !truncated, data.count <= Rules.byteLimit(for: path) else {
            throw AppError(text: "超过预览大小限制，请下载后打开。")
        }
        switch media {
        case .image: return .image(try decodeImage(data, path: path))
        case .pdf: return .pdf(try decodePDF(data))
        }
    }

    private static func decodeImage(_ data: Data, path: String) throws -> CGImage {
        typealias Rules = RepositoryFilePreviewRules
        let invalid = AppError(text: "图片内容无效或与文件格式不符，请下载后检查。")
        let oversized = AppError(text: "图片尺寸无效或超过预览限制，请下载后打开。")
        guard let expectedType = Rules.imageTypeIdentifier(for: path, bytes: data) else { throw invalid }
        guard Rules.imageCanvasFits(type: expectedType, bytes: data) else { throw oversized }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), (type as String) == expectedType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { throw invalid }
        guard Rules.imageDimensionsFit(width: width, height: height) else { throw oversized }
        // Index 0 only, including animated GIF/WebP. Eagerly decode the oriented
        // thumbnail here rather than when SwiftUI first draws the view.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw invalid }
        return image
    }

    private static func decodePDF(_ data: Data) throws -> PDFDocument {
        guard RepositoryFilePreviewRules.isPDF(data), let document = PDFDocument(data: data), !document.isLocked,
              document.pageCount > 0 else { throw AppError(text: "PDF 无效或受密码保护，请下载后打开。") }
        guard document.pageCount <= 250 else { throw AppError(text: "PDF 页数超过预览限制，请下载后打开。") }
        let interactive: Set<String> = ["Link", "Widget", "Screen", "FileAttachment", "Movie", "Sound", "3D", "RichMedia"]
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            // PDFKit can otherwise handle a tap on an annotation itself. Don't
            // hand links/forms/attachments to the view, or alter downloaded bytes.
            guard let page = document.page(at: index) else { throw AppError(text: "PDF 页面无法读取，请下载后检查。") }
            for annotation in page.annotations {
                let subtype = annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
                if interactive.contains(subtype) || annotation.action != nil { page.removeAnnotation(annotation) }
            }
        }
        return document
    }
}

struct RepositoryFilePreviewBody: View {
    let preview: RepositoryFilePreview
    let path: String

    var body: some View {
        switch preview {
        case let .text(text, notice, _):
            VStack(spacing: 0) {
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                SourceCodeView(text: text, filename: path)
            }
        case let .image(image):
            Image(image, scale: 1, label: Text((path as NSString).lastPathComponent))
                .resizable().scaledToFit().padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .pdf(document):
            RepositoryPDFPreviewView(document: document)
        }
    }
}

private struct RepositoryPDFPreviewView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = NonInteractivePDFView()
        view.delegate = view
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: nil)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        view.autoScales = true
    }

    private final class NonInteractivePDFView: PDFView, PDFViewDelegate {
        // Page navigation and zoom remain native, but annotation actions (including
        // remote go-to or launch) and URL callbacks never leave the preview.
        override func perform(_ action: PDFAction) {}
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
        func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}
    }
}
