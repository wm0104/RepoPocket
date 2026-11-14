import UIKit
import UniformTypeIdentifiers

private final class ImportCancellation {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let save = UIButton(type: .system)
    private var task: Task<Void, Never>?
    private var progress: Progress?
    private let cancellation = ImportCancellation()
    private var finished = false
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let title = UILabel(); title.text = "存到 RepoPocket"; title.font = .preferredFont(forTextStyle: .title2)
        status.numberOfLines = 0
        status.text = "文件将复制到“待上传文件”，之后在 RepoPocket 的提交 / 发布页面选择上传。原文件会保留。"
        save.setTitle("保存文件", for: .normal)
        save.addTarget(self, action: #selector(start), for: .touchUpInside)
        let close = UIButton(type: .system); close.setTitle("关闭", for: .normal)
        close.addTarget(self, action: #selector(closeShare), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, status, save, close]); stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32)])
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancellation.cancel(); progress?.cancel(); task?.cancel()
    }
    @objc private func closeShare() {
        cancellation.cancel(); progress?.cancel(); task?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
    @objc private func start() {
        guard task == nil, !finished else { return }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= 20 else { status.text = "一次请选择 1–20 个文件。"; return }
        save.isEnabled = false
        task = Task { @MainActor in
            var imported = 0
            var errors: [String] = []
            do {
                let store = try ShareInboxStore.live()
                for (index, provider) in providers.enumerated() {
                    try Task.checkCancellation()
                    status.text = "正在复制 \(index + 1)/\(providers.count)…"
                    do { try await copy(provider, to: store); imported += 1 }
                    catch is CancellationError { throw CancellationError() }
                    catch { errors.append(error.localizedDescription) }
                }
                finished = true
                status.text = "已保存 \(imported) 个文件。打开 RepoPocket → 提交 / 发布 → 待上传文件。" + (errors.isEmpty ? "" : "\n未导入：" + errors.joined(separator: "\n"))
            } catch { status.text = error.localizedDescription }
            task = nil
            save.isEnabled = !finished && !cancellation.isCancelled
        }
    }
    private func copy(_ provider: NSItemProvider, to store: ShareInboxStore) async throws {
        let cancellation = self.cancellation
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                    do {
                        if let error { throw error }
                        guard let source = value as? URL else { throw ShareInboxError.invalidFile }
                        _ = try store.importFile(source, cancelled: { cancellation.isCancelled })
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } else {
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true || UTType($0)?.conforms(to: .item) == true }) else { throw ShareInboxError.invalidFile }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                progress = provider.loadFileRepresentation(forTypeIdentifier: type) { source, error in
                    do {
                        if let error { throw error }
                        guard let source else { throw ShareInboxError.invalidFile }
                        var name = provider.suggestedName ?? source.lastPathComponent
                        if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension { name += "." + ext }
                        // The provider's temporary URL is valid only until this callback returns.
                        _ = try store.importFile(source, name: name, cancelled: { cancellation.isCancelled })
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
