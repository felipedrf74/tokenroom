import SwiftUI

struct ProviderIcon: View {
    var provider: Provider
    var size: CGFloat = 16

    var body: some View {
        ProviderMark(provider: provider, size: size)
    }
}
