import SwiftUI

/// Initials on a color derived from the email address, as in Spark.
struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(AvatarPalette.color(for: email).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(AvatarPalette.initials(for: name, email: email))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

enum AvatarPalette {
    static let colors: [Color] = [
        .blue, .indigo, .purple, .pink, .red, .orange, .teal, .green, .cyan, .brown, .mint,
    ]

    static func color(for email: String) -> Color {
        colors[stableHash(email.lowercased()) % colors.count]
    }

    static func initials(for name: String, email: String) -> String {
        let source = name.isEmpty ? email : name
        let words = source.split { $0 == " " || $0 == "." || $0 == "_" }.filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first)
        if letters.isEmpty {
            return String(source.prefix(1)).uppercased()
        }
        return String(letters).uppercased()
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return Int(hash % UInt64(Int.max))
    }
}
