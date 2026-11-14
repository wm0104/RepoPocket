import SwiftUI

/// Matches the repository file list, including its icon tile and leading text.
struct LocalGitFileLabel: View {
    let name: String
    var size: Int64? = nil
    var detail = ""
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: name.lowercased().hasSuffix(".deb") ? "shippingbox.fill" : "doc.text.fill")
                .font(.title3).foregroundColor(.accentColor)
                .frame(width: 40, height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).foregroundColor(.primary).multilineTextAlignment(.leading).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if let size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).monospacedDigit() }
                    if !detail.isEmpty { Text(detail) }
                }.font(.caption).foregroundColor(.secondary)
            }
        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
}
