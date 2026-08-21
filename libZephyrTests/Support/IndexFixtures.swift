import Foundation

@testable import libZephyr

/// Creates an empty index in a fresh temporary directory, returned alongside
/// that directory so the test can delete the whole thing when it finishes.
func makeStore(mode: SyncIndexStore.AccessMode = .readWrite) throws -> (SyncIndexStore, URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("zephyr-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("index.sqlite")
  return (try SyncIndexStore(url: url, mode: mode), directory)
}

/// An indexed file, with the path supplying the normalized path, parent, and name.
func fileRecord(
  id: String,
  path: String,
  revision: String = "015d1a1f3f2e5c0000000012a7650",
  hash: String = String(repeating: "ab", count: 32),
  size: UInt64 = 42
) throws -> IndexEntryRecord {
  let display = try DropboxPath(validating: path)
  return IndexEntryRecord(
    dbxID: try DropboxFileIdentifier(validating: id),
    pathNormalized: display.normalized,
    parentPathNormalized: display.normalized.parent,
    pathCased: display,
    name: display.basename,
    itemType: .file,
    revision: try FileRevision(validating: revision),
    contentHash: try ContentHash(validating: hash),
    symlinkTarget: nil,
    size: size,
    clientModified: Date(timeIntervalSince1970: 1_000_000),
    serverModified: Date(timeIntervalSince1970: 1_000_100)
  )
}

/// An indexed folder, with the path supplying the normalized path, parent, and name.
func folderRecord(id: String, path: String) throws -> IndexEntryRecord {
  let display = try DropboxPath(validating: path)
  return IndexEntryRecord(
    dbxID: try DropboxFileIdentifier(validating: id),
    pathNormalized: display.normalized,
    parentPathNormalized: display.normalized.parent,
    pathCased: display,
    name: display.basename,
    itemType: .folder,
    revision: nil,
    contentHash: nil,
    symlinkTarget: nil,
    size: nil,
    clientModified: nil,
    serverModified: nil
  )
}

/// A recorded change to one item, the shape the base-revision lookup reads.
func historyEvent(
  id: String,
  path: String,
  revision: String,
  hash: ContentHash
) throws -> HistoryEventRecord {
  HistoryEventRecord(
    dbxID: try DropboxFileIdentifier(validating: id),
    path: try DropboxPath(validating: path),
    itemType: .file,
    changeType: .modified,
    direction: .down,
    size: 42,
    revision: try FileRevision(validating: revision),
    contentHash: hash
  )
}

/// A checkpointed chunked upload, the shape the uploader resumes from.
func uploadSession(
  path: String,
  sessionID: String,
  committedOffset: UInt64,
  prefixHash: ContentHash,
  startedAt: Date = Date()
) throws -> UploadSessionRecord {
  UploadSessionRecord(
    pathNormalized: try DropboxPath(validating: path).normalized,
    sessionID: try UploadSessionIdentifier(validating: sessionID),
    committedOffset: committedOffset,
    prefixHash: prefixHash,
    startedAt: startedAt
  )
}

/// A failure recorded against a path, with the title and detail the UI shows.
func syncError(path: String, title: String, detail: String? = nil) throws -> SyncErrorRecord {
  SyncErrorRecord(
    pathNormalized: try NormalizedDropboxPath(validating: path),
    path: try DropboxPath(validating: path),
    title: title,
    detail: detail
  )
}

func cursor(_ value: String) throws -> DeltaCursor {
  try DeltaCursor(validating: value)
}
