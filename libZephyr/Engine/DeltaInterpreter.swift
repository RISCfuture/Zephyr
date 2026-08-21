import Foundation

/**
 Turns one page of Dropbox delta entries into index mutations and history
 events. Pure logic — all state comes in through the arguments.

 Dropbox guarantees that replaying entries in order reproduces the remote
 state, so entries apply in server order. An entry whose identifier is already
 indexed at a different path is a move and simply updates that row.
 */
enum DeltaInterpreter {

  /**
   Interprets a page of entries.

   - Parameters:
     - entries: The page's entries, in server order.
     - isKnown: Whether an identifier is already in the index (drives
       added-versus-modified history classification).
   */
  static func interpret(
    entries: [ItemMetadata],
    isKnown: (DropboxFileIdentifier) -> Bool
  ) -> Interpretation {
    var mutations: [IndexMutation] = []
    var history: [HistoryEventRecord] = []

    for entry in syncable(entries) {
      switch entry {
        case .file(let file):
          guard let record = fileRecord(file) else { continue }
          mutations.append(.upsert(record))
          history.append(fileEvent(file, itemType: record.itemType, isKnown: isKnown(file.id)))
        case .folder(let folder):
          guard let record = folderRecord(folder) else { continue }
          mutations.append(.upsert(record))
          if !isKnown(folder.id) { history.append(folderEvent(folder)) }
        case .deleted(let deleted):
          guard let pathLower = deleted.pathLower else { continue }
          mutations.append(.deleteSubtree(pathLower))
          history.append(deletionEvent(deleted))
      }
    }
    return Interpretation(mutations: mutations, history: history)
  }

  /// The entries that may enter the index: another client's `.DS_Store` or
  /// `desktop.ini` would collide with the one Finder writes for itself.
  /// Tombstones always survive, so an excluded name that is already in the
  /// index can still leave it.
  private static func syncable(_ entries: [ItemMetadata]) -> [ItemMetadata] {
    entries.filter { entry in
      if case .deleted = entry { return true }
      guard let pathDisplay = entry.pathDisplay else { return true }
      return !ExcludedNames.isExcluded(path: pathDisplay.normalized)
    }
  }

  /// The path history records for an entry, falling back to its bare name at
  /// the root when the server omitted the path (an unmounted share).
  private static func displayPath(_ pathDisplay: DropboxPath?, named name: String) -> DropboxPath {
    if let pathDisplay { return pathDisplay }
    return (try? DropboxPath.root.appending(name)) ?? .root
  }

  /// The index row for a file's metadata, or `nil` when the server omitted
  /// its paths (an unmounted share).
  static func fileRecord(_ file: FileMetadata) -> IndexEntryRecord? {
    guard let pathLower = file.pathLower, let pathDisplay = file.pathDisplay else { return nil }
    return IndexEntryRecord(
      dbxID: file.id,
      pathNormalized: pathLower,
      parentPathNormalized: pathLower.parent,
      pathCased: pathDisplay,
      name: file.name,
      itemType: file.symlinkTarget == nil ? .file : .symlink,
      revision: file.rev,
      contentHash: file.contentHash,
      symlinkTarget: file.symlinkTarget,
      size: file.size,
      clientModified: file.clientModified,
      serverModified: file.serverModified
    )
  }

  /// The index row for a folder's metadata, or `nil` when the server omitted
  /// its paths (an unmounted share).
  static func folderRecord(_ folder: FolderMetadata) -> IndexEntryRecord? {
    guard let pathLower = folder.pathLower, let pathDisplay = folder.pathDisplay else { return nil }
    return IndexEntryRecord(
      dbxID: folder.id,
      pathNormalized: pathLower,
      parentPathNormalized: pathLower.parent,
      pathCased: pathDisplay,
      name: folder.name,
      itemType: .folder,
      revision: nil,
      contentHash: nil,
      symlinkTarget: nil,
      size: nil,
      clientModified: nil,
      serverModified: nil
    )
  }

  /// The history event for a file the server reported, recorded as a
  /// modification when the index already knows the identifier and as an
  /// addition when it does not.
  private static func fileEvent(
    _ file: FileMetadata,
    itemType: IndexItemType,
    isKnown: Bool
  ) -> HistoryEventRecord {
    HistoryEventRecord(
      dbxID: file.id,
      path: displayPath(file.pathDisplay, named: file.name),
      itemType: itemType,
      changeType: isKnown ? .modified : .added,
      direction: .down,
      size: file.size,
      revision: file.rev,
      contentHash: file.contentHash,
      modifiedBy: file.modifiedBy
    )
  }

  /// The history event for a folder the index has not seen before.
  private static func folderEvent(_ folder: FolderMetadata) -> HistoryEventRecord {
    HistoryEventRecord(
      dbxID: folder.id,
      path: displayPath(folder.pathDisplay, named: folder.name),
      itemType: .folder,
      changeType: .added,
      direction: .down,
      size: nil,
      revision: nil,
      contentHash: nil
    )
  }

  /// The history event for a tombstone. A tombstone carries no identifier and
  /// does not say what the removed item was, so it records as a file.
  private static func deletionEvent(_ deleted: DeletedMetadata) -> HistoryEventRecord {
    HistoryEventRecord(
      dbxID: nil,
      path: displayPath(deleted.pathDisplay, named: deleted.name),
      itemType: .file,
      changeType: .removed,
      direction: .down,
      size: nil,
      revision: nil,
      contentHash: nil
    )
  }

  /// The result of interpreting a page.
  struct Interpretation: Sendable {
    let mutations: [IndexMutation]
    let history: [HistoryEventRecord]
  }
}
