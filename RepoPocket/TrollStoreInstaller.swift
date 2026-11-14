import Foundation
import UIKit

/// URL dispatch is not an installation result; TrollStore owns the transfer and confirmation.
@MainActor enum TrollStoreInstaller {
    static func open(ipaURL: URL, completion: @escaping (Bool) -> Void) {
        guard let url = TrollStoreInstallRules.installURL(for: ipaURL),
              UIApplication.shared.canOpenURL(url) else { completion(false); return }
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in completion(opened) }
        }
    }
}
