import Foundation

/**
 Names that never travel to Dropbox: system metadata files and
 temporary-file patterns, matching Maestral's always-excluded set.

 Exclusion applies to a whole path, not just its last component, so nothing
 inside an excluded folder syncs either — the rule Maestral spells as its
 separate `EXCLUDED_DIR_NAMES` first-component test.
 */
enum ExcludedNames {
  private static let names: Set<String> = [
    "desktop.ini",
    "thumbs.db",
    ".ds_store",
    "icon\r",
    ".dropbox",
    ".dropbox.attr",
    ".dropbox.cache",
    ".localized"
  ]

  /// Whether a filename is excluded from upload.
  static func isExcluded(_ name: String) -> Bool {
    let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
    if names.contains(normalized) { return true }
    // Office and editor temp files: "~$lockfile.docx", ".~lock.ods", "~something.tmp".
    if normalized.hasPrefix("~$") || normalized.hasPrefix(".~") { return true }
    if normalized.hasPrefix("~"), normalized.hasSuffix(".tmp") { return true }
    return false
  }

  /// Whether a Dropbox path is excluded — because its own name is, or
  /// because it sits inside a folder whose name is.
  static func isExcluded(path: NormalizedDropboxPath) -> Bool {
    path.rawValue.split(separator: "/").contains { isExcluded(String($0)) }
  }
}
