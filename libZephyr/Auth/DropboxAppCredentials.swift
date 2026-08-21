import Foundation

/**
 Zephyr's Dropbox app registration.

 The app key is an OAuth public client identifier — it is not a secret, and no
 client secret is ever sent (Zephyr uses PKCE). The key is injected at build
 time from `Config/Secrets.xcconfig` into the framework's Info.plist; see
 `Config/Secrets.example.xcconfig` for how to register and configure one.
 */
public enum DropboxAppCredentials {
  /// The OAuth client identifier of Zephyr's Dropbox app registration.
  public static let appKey =
    #bundle.object(forInfoDictionaryKey: "DropboxAppKey") as? String ?? ""

  /// Whether an app key was configured at build time (see `Config/Secrets.example.xcconfig`).
  public static var isConfigured: Bool { !appKey.isEmpty }

  // periphery:ignore
  /**
   The OAuth scopes Zephyr's app registration must enable.

   The authorization request sends no `scope` parameter, so Dropbox grants
   whatever the app's console registration enables — this list is what
   `README.md` and `Config/Secrets.example.xcconfig` send a reader here to copy.
   */
  public static let scopes = [
    "account_info.read",
    "files.metadata.read",
    "files.content.read",
    "files.content.write",
    "sharing.read",
    "sharing.write"
  ]
}
