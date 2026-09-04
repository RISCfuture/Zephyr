public import Foundation

/**
 The `com.dropbox.ignored` extended-attribute convention shared with the
 official Dropbox client: a marked item stays on disk but stops syncing, and
 its remote copy is removed.
 */
public enum DropboxIgnoreMarker {
  /// The extended attribute's base name.
  public static let xattrName = "com.dropbox.ignored"

  /**
   The spelling that actually syncs: macOS embeds extended-attribute flags
   in the name after a `#`, and only names flagged syncable (`S`) travel
   through the File Provider metadata plane — a plain `com.dropbox.ignored`
   write never reaches the provider.
   */
  public static let syncableXattrName = "com.dropbox.ignored#S"

  /// The attribute value written when marking an item.
  public static let markedValue = Data("1".utf8)

  /// Whether an extended-attribute dictionary marks its item as ignored,
  /// under any flags spelling of the name. Any value except an explicit
  /// `0` counts as marked, matching `xattr -w 'com.dropbox.ignored#S' 1`.
  public static func isMarked(_ xattrs: [String: Data]) -> Bool {
    xattrs.contains { key, value in
      baseName(of: key) == xattrName
        && String(bytes: value, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }
  }

  /// Removes every flags spelling of the marker from a dictionary.
  public static func removingMarker(from xattrs: [String: Data]) -> [String: Data] {
    xattrs.filter { baseName(of: $0.key) != xattrName }
  }

  /// An extended-attribute name with its `#`-embedded flags stripped.
  private static func baseName(of key: String) -> String {
    key.firstIndex(of: "#").map { String(key[..<$0]) } ?? key
  }
}
