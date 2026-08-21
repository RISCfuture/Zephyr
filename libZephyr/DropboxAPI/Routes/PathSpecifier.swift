import Foundation

/**
 The forms Dropbox path parameters accept: a display path, an `id:` file
 identifier, a `rev:` pseudo-path pinning one revision, or an `ns:` pseudo-path
 addressing a namespace other than the call's path root.
 */
public enum PathSpecifier: Sendable, Equatable {
  case path(DropboxPath)

  case id(DropboxFileIdentifier)

  case revision(FileRevision)

  /**
   A path relative to an explicit namespace, such as a team member's home
   folder inside a team space.

   - Parameters:
     - namespaceID: The namespace to resolve against.
     - path: The path within that namespace; `nil` addresses its root.
   */
  case namespace(NamespaceIdentifier, path: DropboxPath?)

  /// The string sent on the wire.
  public var wireValue: String {
    switch self {
      case .path(let path): path.rawValue
      case .id(let identifier): identifier.rawValue
      case .revision(let revision): "rev:\(revision.rawValue)"
      case let .namespace(namespaceID, path):
        "ns:\(namespaceID.rawValue)\(path?.rawValue ?? "")"
    }
  }

  /// The root of a namespace other than the call's path root.
  public static func namespaceRoot(_ namespaceID: NamespaceIdentifier) -> Self {
    .namespace(namespaceID, path: nil)
  }
}
