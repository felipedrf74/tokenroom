import SwiftUI

/// The provider's icon in the popover and Settings: `ProviderMark`, the same on every platform.
struct ProviderIcon: View {
    var provider: Provider
    var size: CGFloat = 16

    var body: some View {
        ProviderMark(provider: provider, size: size)
    }
}
