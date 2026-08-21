import Foundation

/**
 What the version-history sheet needs from the account layer: what the index
 knows about the file, the revisions Dropbox kept of it, and a way to put one
 back.

 The sheet reaches Dropbox through this and nothing else, so its tests can
 stand in for the network without standing in for the sheet.
 ``SharedAccountService`` is the live implementation; it already vended all
 three for the Shortcuts actions.
 */
public protocol FileVersionsService: Sendable {
  /// The index's row for a file, or `nil` when the account has no index or the
  /// file is not in it.
  func indexedItem(
    _ item: DropboxFileIdentifier,
    in account: AccountIdentifier
  ) async throws -> IndexEntryRecord?

  /// The file's stored revisions, most recent first.
  func revisions(
    of item: DropboxFileIdentifier,
    in account: AccountIdentifier,
    limit: UInt
  ) async throws -> [FileMetadata]

  /// Puts the file back to an earlier revision.
  func restore(
    _ path: DropboxPath,
    to revision: FileRevision,
    in account: AccountIdentifier
  ) async throws -> FileMetadata
}
