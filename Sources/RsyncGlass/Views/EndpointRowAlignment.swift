import SwiftUI

/// Aligns the source→target arrow with each EndpointEditor's Local/Remote
/// picker row, regardless of how tall either panel ends up (Local vs Remote
/// mode have very different heights, so a fixed offset can't work here).
struct EndpointRowAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    static let endpointRow = VerticalAlignment(EndpointRowAlignment.self)
}
