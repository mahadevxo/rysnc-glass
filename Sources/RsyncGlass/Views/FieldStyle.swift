import SwiftUI

/// A flatter, subtler text field treatment than `.roundedBorder` — closer to
/// the fields Apple uses inside grouped panels in System Settings.
extension View {
    func fieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
