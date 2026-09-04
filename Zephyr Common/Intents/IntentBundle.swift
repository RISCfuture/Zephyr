import AppIntents
public import Foundation

/// Anchors bundle lookup for this framework's App Intents metadata.
private final class BundleAnchor {}

extension LocalizedStringResource.BundleDescription {
  /// Where App Intents strings defined in `ZephyrCommon` are translated. See
  /// the same property on `libZephyr` for why these do not use `#bundle`.
  public static let zephyrCommon = Self.forClass(BundleAnchor.self)
}
