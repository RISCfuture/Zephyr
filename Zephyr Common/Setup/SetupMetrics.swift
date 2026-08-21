import SwiftUI

/**
 The one gap setup keeps to itself.

 Everything else about a setup page's rhythm comes from ``Metrics``, which
 every window shares. This is the exception: a list of things setup is about to
 ask for reads as a list, and its rows sit further apart than default without
 becoming separate groups.
 */
enum SetupMetrics {
  /// Between the rows of a list, which are alike enough to sit closer than two
  /// unrelated groups without being one thing.
  static let betweenRows: CGFloat = 12
}
