import SwiftUI

struct NanoMark: View {
    var color: Color = .primary

    var body: some View {
        Image("NanoMark")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}
