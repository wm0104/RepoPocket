import SwiftUI
import UniformTypeIdentifiers
import UIKit

// One immutable request is both the sheet identity and its import mode.
struct WorkspaceImportRequest: Identifiable {
    enum Kind { case folder, zip }
    let id = UUID()
    let kind: Kind
    var isZIP: Bool { kind == .zip }
}

// Native picker avoids SwiftUI fileImporter's iOS 16 folder-provider regressions.
struct WorkspaceDocumentPicker: UIViewControllerRepresentable {
    let request: WorkspaceImportRequest
    var allowsMultipleSelection = true
    var cancelTitle = "取消导入"
    let completion: ([URL]?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> WorkspacePickerContainer {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: request.isZIP ? [.zip] : [.folder], asCopy: false)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return WorkspacePickerContainer(picker: picker, title: request.isZIP ? "导入 ZIP" : "选择文件夹", cancelTitle: cancelTitle, cancel: { context.coordinator.finish(nil) })
    }
    func updateUIViewController(_ controller: WorkspacePickerContainer, context: Context) {
        context.coordinator.completion = completion
    }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var completion: ([URL]?) -> Void
        private var finished = false
        init(_ completion: @escaping ([URL]?) -> Void) { self.completion = completion }
        func finish(_ urls: [URL]?) {
            guard !finished else { return }
            finished = true
            completion(urls)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    }
}

// Public view-controller containment only. The app's Cancel remains outside the
// Files navigation hierarchy, even when a provider hides its own Cancel button.
final class WorkspacePickerContainer: UIViewController {
    private let picker: UIDocumentPickerViewController
    private let heading: String
    private let cancelTitle: String
    private let cancel: () -> Void
    init(picker: UIDocumentPickerViewController, title: String, cancelTitle: String = "取消导入", cancel: @escaping () -> Void) {
        self.picker = picker; self.heading = title; self.cancelTitle = cancelTitle; self.cancel = cancel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 12
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        let label = UILabel()
        label.text = heading
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = UIButton(type: .system)
        button.setTitle(cancelTitle, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = "workspace.import.cancel"
        button.addTarget(self, action: #selector(cancelImport), for: .touchUpInside)
        bar.addArrangedSubview(label)
        bar.addArrangedSubview(button)
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        addChild(picker)
        picker.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker.view)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            picker.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            picker.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        picker.didMove(toParent: self)
    }
    @objc private func cancelImport() { cancel() }
}
