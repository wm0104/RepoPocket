import SwiftUI

struct SocialAccountIcon: View {
    let url: String
    var provider = "generic"

    var body: some View {
        Group {
            if let platform = SocialPlatform.identify(url: url, provider: provider) {
                Image("social-" + platform.rawValue)
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(color(platform))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 21)).foregroundStyle(.secondary)
            }
        }.frame(width: 26, height: 26, alignment: .center).accessibilityHidden(true)
    }

    private func color(_ platform: SocialPlatform) -> Color {
        let hex: UInt32
        switch platform {
        case .telegram: hex = 0x26A5E4
        case .x, .threads, .tiktok, .github: return .primary
        case .mastodon: hex = 0x6364FF
        case .bluesky: hex = 0x0285FF
        case .instagram: hex = 0xE4405F
        case .youtube: hex = 0xFF0000
        case .discord: hex = 0x5865F2
        case .whatsapp: hex = 0x16883E
        case .bilibili: hex = 0xE44F88
        }
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
