import SwiftUI

extension View {
    func appTextInputAlert(_ title: String, message: String, isPresented: Binding<Bool>,
                           text: Binding<String>, placeholder: String, confirmTitle: String,
                           enabled: Bool = true, verbatimInput: Bool = true,
                           confirmAction: @escaping () -> Void) -> some View {
        modifier(AppTextInputAlert(title: title, message: message, isPresented: isPresented,
                                   text: text, placeholder: placeholder, confirmTitle: confirmTitle,
                                   enabled: enabled, verbatimInput: verbatimInput, confirmAction: confirmAction))
    }
}

/// SwiftUI alert text fields are ignored on iOS 15; keep a native input surface there.
private struct AppTextInputAlert: ViewModifier {
    let title: String
    let message: String
    @Binding var isPresented: Bool
    @Binding var text: String
    let placeholder: String
    let confirmTitle: String
    let enabled: Bool
    let verbatimInput: Bool
    let confirmAction: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alert(title, isPresented: $isPresented) {
                inputField
                // Keep enabled actions as plain Buttons for SwiftUI's alert bridge.
                if enabled {
                    Button(confirmTitle) { confirm() }
                } else {
                    Button(confirmTitle) {}.disabled(true)
                }
                Button("取消", role: .cancel) { isPresented = false }
            } message: { Text(message) }
        } else {
            content.sheet(isPresented: $isPresented) {
                NavigationView {
                    Form {
                        Section {
                            inputField
                        } footer: { Text(message) }
                    }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消", role: .cancel) { isPresented = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(confirmTitle) { confirm() }.disabled(!enabled)
                        }
                    }
                }.navigationViewStyle(.stack)
            }
        }
    }

    @ViewBuilder private var inputField: some View {
        if verbatimInput {
            TextField(placeholder, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
        } else {
            TextField(placeholder, text: $text)
        }
    }

    private func confirm() {
        guard enabled else { return }
        // Run before clearing optional-route bindings; callers also capture their target.
        confirmAction()
        isPresented = false
    }
}
