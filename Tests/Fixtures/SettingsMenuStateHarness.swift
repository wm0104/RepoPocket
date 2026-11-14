// Compiled by test_settings_menu_state.py with production menu code and UIKit mocks.
// This tests state/callback behavior, not UIKit hit testing or SwiftUI toolbar lifecycle.
struct SettingsThemeFixture {
    let store: UserDefaults
    init(_ store: UserDefaults) { self.store = store }
    var appearance: String {
        get { store.string(forKey: "appearance.mode") ?? "system" }
        nonmutating set { store.set(newValue, forKey: "appearance.mode") }
    }
    func items() -> [NativeMenuItem] {
        // PRODUCTION_THEME_EXPRESSION
    }
}

@main struct SettingsMenuHarness {
    @MainActor static func main() async throws {
        let suite = "RepoPocket-settings-tests-" + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let settings = SettingsThemeFixture(store)
        let coordinator = Coordinator()
        coordinator.items = settings.items()
        let button = UIButton(); coordinator.installMenu(on: button)
        let root = button.menu!
        let deferred = root.children[0] as! UIDeferredMenuElement
        func actions() -> [UIAction] {
            var result: [UIAction] = []
            deferred.provider { result = $0.map { $0 as! UIAction } }
            precondition(button.menu === root)
            return result
        }
        func check(_ mode: String) {
            let resolved = actions()
            precondition(resolved.filter { $0.state == .on }.count == 1)
            let index = ["system", "light", "dark"].firstIndex(of: mode)!
            precondition(resolved[index].state == .on)
            precondition(settings.appearance == mode)
        }
        check("system")
        // Keep the same descriptions/coordinator/root, as with no SwiftUI update yet.
        for mode in ["dark", "light", "system", "light", "dark"] {
            settings.appearance = mode
            check(mode)
        }
        for (index, mode) in ["system", "light", "dark"].enumerated() {
            let before = settings.appearance
            actions()[index].tap()
            precondition(settings.appearance == before, "Action must not run synchronously")
            try await Task.sleep(nanoseconds: 1_000_000)
            check(mode)
        }
        let reloaded = SettingsThemeFixture(UserDefaults(suiteName: suite)!)
        coordinator.items = reloaded.items()
        check("dark")
        // Recreating the toolbar must also read the stored mode, not a default snapshot.
        let rebuilt = Coordinator()
        rebuilt.items = reloaded.items()
        let rebuiltButton = UIButton(); rebuilt.installMenu(on: rebuiltButton)
        var rebuiltActions: [UIAction] = []
        (rebuiltButton.menu!.children[0] as! UIDeferredMenuElement).provider {
            rebuiltActions = $0.map { $0 as! UIAction }
        }
        precondition(rebuiltActions.map { $0.state == .on } == [false, false, true])
        // A live false must override a selected snapshot; absent callbacks keep compatibility.
        rebuilt.items = [
            NativeMenuItem(id: "live-false", title: "实时未选", selected: true, selectedState: { false }),
            NativeMenuItem(id: "snapshot-on", title: "快照选中", selected: true),
            NativeMenuItem(id: "snapshot-off", title: "快照未选")
        ]
        let fallbackActions = rebuilt.elements().map { $0 as! UIAction }
        precondition(fallbackActions.map { $0.state == .on } == [false, true, false])
        let old = actions()[1]
        coordinator.items = []
        old.tap()
        try await Task.sleep(nanoseconds: 1_000_000)
        precondition(settings.appearance == "dark")
        print("PASS live stored selection, repeated uncached opens, async theme writes, reload preservation and removed action guard")
    }
}
