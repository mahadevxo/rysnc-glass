import SwiftUI

extension View {
    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        self
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
