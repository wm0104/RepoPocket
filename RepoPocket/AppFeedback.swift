import Combine
import SPIndicator
import UIKit

/// Completed operations only. Async local work must pass its starting account generation.
@MainActor
enum AppFeedback {
    static func show(_ title: String, session: UUID = AccountStore.generation) {
        guard session == AccountStore.generation else { return }
        presenter.enqueue(title, session: session)
    }

    static func show(_ title: String, api: GitHub) {
        guard api.isCurrentSession else { return }
        show(title, session: AccountStore.generation)
    }

    #if DEBUG
    // A test-only witness of the real scene event, not XCTest's Home command duration.
    static var deactivationEvidence: (id: UUID, title: String, sceneID: String, elapsed: TimeInterval)?
    static let lifecycleObservation = AppFeedbackLifecycleObservation()
    static var lifecycleTestEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-style-preview") && args.contains("-download-completion-style-preview")
            && args.contains("-feedback-lifecycle-style-preview")
    }
    #endif

    private static let presenter = AppFeedbackPresenter()
}

#if DEBUG
/// Publishes each real activation independently of the preview view's subscriptions.
@MainActor
final class AppFeedbackLifecycleObservation: ObservableObject {
    @Published private(set) var value = "0|none"
    private var activationCount = 0
    var sceneID: String?

    func reset() {
        AppFeedback.deactivationEvidence = nil
        value = String(activationCount) + "|none"
    }

    func activate(_ scene: UIWindowScene) {
        guard scene.session.persistentIdentifier == sceneID else { return }
        let evidence = AppFeedback.deactivationEvidence
        AppFeedback.deactivationEvidence = nil
        activationCount += 1
        let prefix = String(activationCount) + "|"
        if let evidence, evidence.sceneID == sceneID {
            value = prefix + evidence.id.uuidString + "|" + evidence.title + "|" + String(evidence.elapsed)
        } else {
            value = prefix + "none"
        }
    }
}
#endif

// MARK: - Queue

/// Kept independent of UIKit so lifecycle and stale-account behavior can be host-tested.
struct AppFeedbackQueue {
    struct Item {
        let id = UUID()
        let title: String
        let session: UUID
        var sceneID: String?
    }
    private(set) var pending: [Item] = []
    private(set) var current: Item?

    mutating func append(_ title: String, session: UUID) {
        pending.append(Item(title: title, session: session))
    }

    mutating func take(session: UUID, sceneID: String) -> Item? {
        guard current == nil else { return nil }
        pending.removeAll { $0.session != session }
        guard let index = pending.firstIndex(where: { $0.sceneID == nil || $0.sceneID == sceneID }) else { return nil }
        var item = pending.remove(at: index)
        item.sceneID = sceneID
        current = item
        return item
    }

    mutating func disconnect(sceneID: String) {
        pending.removeAll { $0.sceneID == sceneID }
        if current?.sceneID == sceneID { current = nil }
    }

    mutating func finish(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
    }

    mutating func suspend() {
        // A result already shown is consumed, even when its scene deactivates early.
        current = nil
    }

    mutating func clear() {
        current = nil
        pending.removeAll()
    }
}

// MARK: - Presenter

@MainActor
private final class AppFeedbackPresenter {
    private var queue = AppFeedbackQueue()
    private var window: FeedbackPassthroughWindow?
    private var indicator: SPIndicatorView?
    #if DEBUG
    private var presentation: (id: UUID, uptime: TimeInterval)?
    #endif
    private var observers: Set<AnyCancellable> = []

    init() {
        NotificationCenter.default.publisher(for: .githubAccountChanged)
            .sink { [weak self] _ in
                self?.queue.clear()
                self?.clearWindow()
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] notice in
                #if DEBUG
                if AppFeedback.lifecycleTestEnabled, let scene = notice.object as? UIWindowScene {
                    AppFeedback.lifecycleObservation.activate(scene)
                }
                #endif
                self?.showNext()
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)
            .sink { [weak self] notice in
                guard let self, let scene = notice.object as? UIWindowScene,
                      self.window?.windowScene === scene else { return }
                #if DEBUG
                if AppFeedback.lifecycleTestEnabled {
                    AppFeedback.deactivationEvidence = nil
                    if let item = self.queue.current, let start = self.presentation, start.id == item.id,
                       let indicator = self.indicator, indicator.window === self.window, !indicator.isHidden {
                        AppFeedback.deactivationEvidence = (item.id, item.title, scene.session.persistentIdentifier,
                                                           ProcessInfo.processInfo.systemUptime - start.uptime)
                    }
                }
                #endif
                // Finish the shown result on deactivation; activation only presents new work.
                self.queue.suspend()
                self.clearWindow()
                self.showNext(excluding: scene)
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
            .sink { [weak self] notice in
                guard let self, let scene = notice.object as? UIWindowScene else { return }
                let sceneID = scene.session.persistentIdentifier
                self.queue.disconnect(sceneID: sceneID)
                if self.window?.windowScene?.session.persistentIdentifier == sceneID {
                    self.clearWindow()
                }
                self.showNext(excluding: scene)
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyAppearance() }.store(in: &observers)
    }

    func enqueue(_ title: String, session: UUID) {
        queue.append(title, session: session)
        showNext()
    }

    private func showNext(excluding inactiveScene: UIWindowScene? = nil) {
        guard window == nil else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where scene !== inactiveScene && scene.activationState == .foregroundActive {
            guard let item = queue.take(session: AccountStore.generation,
                                        sceneID: scene.session.persistentIdentifier) else { continue }
            present(item, in: scene)
            return
        }
    }

    private func present(_ item: AppFeedbackQueue.Item, in scene: UIWindowScene) {
        let host = FeedbackPassthroughWindow(windowScene: scene)
        host.windowLevel = .alert + 1
        host.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        host.rootViewController = root
        window = host
        applyAppearance()
        host.isHidden = false
        host.layoutIfNeeded()

        let indicator = FeedbackIndicatorView(title: item.title, message: nil, preset: .done)
        indicator.titleLabel?.adjustsFontForContentSizeCategory = true
        indicator.titleLabel?.numberOfLines = 1
        indicator.isAccessibilityElement = true
        indicator.accessibilityLabel = item.title
        indicator.accessibilityIdentifier = "app-success-feedback"
        indicator.presentWindow = host
        self.indicator = indicator
        #if DEBUG
        if AppFeedback.lifecycleTestEnabled {
            indicator.accessibilityValue = item.id.uuidString
            AppFeedback.lifecycleObservation.sceneID = scene.session.persistentIdentifier
            presentation = (item.id, ProcessInfo.processInfo.systemUptime)
        }
        #endif
        indicator.present(duration: 3, haptic: .none) { [weak self, weak indicator] in
            guard let self, let indicator, self.indicator === indicator else { return }
            self.queue.finish(item.id)
            self.clearWindow()
            self.showNext()
        }
        UIAccessibility.post(notification: .announcement, argument: item.title)
    }

    private func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "appearance.mode") {
        case "dark": window?.overrideUserInterfaceStyle = .dark
        case "light": window?.overrideUserInterfaceStyle = .light
        default: window?.overrideUserInterfaceStyle = .unspecified
        }
    }

    private func clearWindow() {
        // SPIndicator's delayed dismissal may still run; it must not advance a newer queue.
        indicator?.completion = nil
        indicator?.removeFromSuperview()
        indicator = nil
        #if DEBUG
        presentation = nil
        #endif
        window?.isHidden = true
        window = nil
    }
}

private final class FeedbackIndicatorView: SPIndicatorView {
    override func layoutSubviews() {
        super.layoutSubviews()
        // SPIndicator resets this to two while laying out its icon/title grid.
        titleLabel?.numberOfLines = 1
    }
}

private final class FeedbackPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === rootViewController?.view ? nil : hit
    }
}
