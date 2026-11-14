import SwiftUI
import UIKit

/// Mounted only in sorting mode: ordinary cards keep their native menu and navigation.
struct StarListReorderView: UIViewControllerRepresentable {
    let items: [StarListRepository]
    let isCurrent: () -> Bool
    let card: (StarListRepository) -> AnyView
    let commit: ([String]) -> Bool

    func makeUIViewController(context: Context) -> Controller { Controller(configuration: self) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.update(self) }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.dismantle() }

    final class Controller: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        private var configuration: StarListReorderView
        private var items: [StarListRepository]
        private var snapshot: [String]?
        private var movementID: UUID?
        private var lastTarget: IndexPath?
        private var lastFeedback: TimeInterval = 0
        private var layoutWidth: CGFloat = 0
        private let lift = UIImpactFeedbackGenerator(style: .light)
        private let selection = UISelectionFeedbackGenerator()
        private var observer: NSObjectProtocol?
        private lazy var collection: UICollectionView = {
            let layout = UICollectionViewFlowLayout()
            layout.minimumLineSpacing = 0
            layout.sectionInset = UIEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
            let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
            view.backgroundColor = .systemGroupedBackground
            view.alwaysBounceVertical = true
            view.dataSource = self; view.delegate = self
            view.register(CardCell.self, forCellWithReuseIdentifier: "card")
            view.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleReorderLongPress(_:))))
            view.accessibilityIdentifier = "star-list-sort-collection"
            return view
        }()
        init(configuration: StarListReorderView) { self.configuration = configuration; items = configuration.items; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = collection }
        override func viewDidLoad() {
            super.viewDidLoad()
            observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        override func viewWillDisappear(_ animated: Bool) { cancel(); super.viewWillDisappear(animated) }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if layoutWidth != collection.bounds.width {
                layoutWidth = collection.bounds.width
                cancel()
                collection.collectionViewLayout.invalidateLayout()
            }
        }
        func update(_ value: StarListReorderView) {
            let changed = value.items.map(\.id) != configuration.items.map(\.id)
            configuration = value
            if !value.isCurrent() || changed { cancel(); items = value.items; collection.reloadData() }
        }
        func cancel() {
            guard snapshot != nil else { return }
            // Clear before UIKit can deliver any completion callback.
            snapshot = nil; movementID = nil; lastTarget = nil
            collection.cancelInteractiveMovement()
            items = configuration.items
            DispatchQueue.main.async { [weak self] in self?.collection.reloadData() }
        }
        func dismantle() {
            cancel()
            collection.gestureRecognizers?.forEach { $0.isEnabled = false }
            collection.dataSource = nil; collection.delegate = nil
            for host in children {
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            }
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        }
        @objc private func handleReorderLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard configuration.isCurrent() else { cancel(); return }
            let point = gesture.location(in: collection)
            switch gesture.state {
            case .began:
                guard snapshot == nil, let index = collection.indexPathForItem(at: point) else { return }
                lift.prepare(); selection.prepare(); lastFeedback = 0
                movementID = UUID(); snapshot = items.map(\.id); lastTarget = index
                guard collection.beginInteractiveMovementForItem(at: index) else { snapshot = nil; movementID = nil; lastTarget = nil; return }
                lift.impactOccurred()
            case .changed:
                guard snapshot != nil else { return }
                collection.updateInteractiveMovementTargetPosition(point)
            case .ended:
                guard snapshot != nil else { return }
                guard collection.bounds.contains(point) else { cancel(); return }
                let endedID = movementID
                collection.endInteractiveMovement()
                // UIKit owns the final move callback; also clear a drop with no position change.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.movementID == endedID else { return }
                    self.snapshot = nil; self.movementID = nil; self.lastTarget = nil
                    self.collection.reloadData()
                }
            default: cancel()
            }
        }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! CardCell
            let item = items[indexPath.item]
            cell.show(content(at: indexPath.item), in: self)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = item.nameWithOwner
            cell.accessibilityHint = "长按拖动排序，仅保存在本机"
            cell.accessibilityIdentifier = "star-list-sort-" + item.id
            return cell
        }
        private func content(at index: Int) -> AnyView {
            let bottom = index == items.count - 1
            return AnyView(configuration.card(items[index]).padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SoftGroupShape(top: index == 0, bottom: bottom).fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(alignment: .bottom) {
                        if !bottom { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 20) }
                    }).clipShape(Rectangle()))
        }
        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = max(1, collectionView.bounds.width - 40)
            let host = UIHostingController(rootView: content(at: indexPath.item))
            let size: CGSize
            if #available(iOS 16.0, *) {
                size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            } else {
                host.view.bounds.size.width = width
                size = host.view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            }
            return CGSize(width: width, height: max(64, ceil(size.height)))
        }
        func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { configuration.isCurrent() }
        func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
            if snapshot != nil, proposedIndexPath != lastTarget {
                lastTarget = proposedIndexPath
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastFeedback >= 0.08 { selection.selectionChanged(); selection.prepare(); lastFeedback = now }
            }
            return proposedIndexPath
        }
        func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
            guard let snapshot, snapshot == configuration.items.map(\.id), configuration.isCurrent(),
                  items.indices.contains(sourceIndexPath.item), items.indices.contains(destinationIndexPath.item) else { cancel(); return }
            let value = items.remove(at: sourceIndexPath.item); items.insert(value, at: destinationIndexPath.item)
            if !configuration.commit(items.map(\.id)) { items = configuration.items }
            self.snapshot = nil; movementID = nil; lastTarget = nil
            // Do not reload inside UIKit's interactive update transaction.
            DispatchQueue.main.async { [weak self] in self?.collection.reloadData() }
        }
    }

    private final class CardCell: UICollectionViewCell {
        private var host: UIHostingController<AnyView>?
        override func prepareForReuse() {
            super.prepareForReuse()
            host?.willMove(toParent: nil); host?.view.removeFromSuperview(); host?.removeFromParent(); host = nil
            accessibilityIdentifier = nil; accessibilityLabel = nil; accessibilityHint = nil; isAccessibilityElement = false
        }
        func show(_ card: AnyView, in controller: UIViewController) {
            let content = card
            if let host { host.rootView = content; host.view.invalidateIntrinsicContentSize(); return }
            let host = UIHostingController(rootView: content)
            self.host = host
            controller.addChild(host)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
            host.didMove(toParent: controller)
            contentView.clipsToBounds = true
        }
    }
}
