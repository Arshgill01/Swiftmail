import SwiftUI

/// Per-account color for the dot and the unified-list bar.
enum AccountColors {
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]

    static func color(_ index: Int) -> Color {
        palette[index % palette.count]
    }
}

extension Color {
    /// Gmail label colors such as `#16a766`.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
