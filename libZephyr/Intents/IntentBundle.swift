import AppIntents
public import Foundation

/// Anchors bundle lookup for this framework's App Intents metadata.
private final class BundleAnchor {}

extension LocalizedStringResource.BundleDescription {
  /**
   Where App Intents strings defined in `libZephyr` are translated.

   Every other localized string in this framework goes through `#bundle`,
   which resolves in-process at the moment it is read. App Intents does not
   read these: it serializes them into `Metadata.appintents` while the target
   is being built, so the bundle has to be something the extractor can resolve
   statically. `#bundle` is not — it selects
   `LocalizedStringResource(_:bundle: Bundle)`, which forwards to
   `.atURL(bundle.bundleURL)`, a path computed at runtime. Naming a class in
   the bundle is the form that survives extraction.

   So: `String(localized:bundle: #bundle)` everywhere else, and this for
   anything App Intents reads — a title, a parameter, a type display
   representation, an `AppEnum` case.
   */
  public static let libZephyr = Self.forClass(BundleAnchor.self)
}
