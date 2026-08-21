import SwiftUI

/// A sheet's way of saying there is nothing to do here, and why.
///
/// Not an error: the conditions this states are ordinary — nothing shareable
/// was handed over, Dropbox kept no earlier version — and reading them in red
/// would tell the reader something went wrong when nothing did.
struct AdvisoryView: View {
  private let message: LocalizedStringResource
  private let symbol: String

  var body: some View {
    VStack(spacing: 7) {
      Image(systemName: symbol)
        .font(.system(size: 22))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 40)
  }

  init(_ message: LocalizedStringResource, symbol: String) {
    self.message = message
    self.symbol = symbol
  }
}
