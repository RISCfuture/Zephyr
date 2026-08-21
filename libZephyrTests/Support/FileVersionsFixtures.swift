import FileProvider
import Foundation
import Synchronization

@testable import libZephyr

/// The domain identifier a version-history action arrives with, which is what
/// an extension is handed rather than the account identifier itself.
let versionsDomainIdentifier = "AAH4f99T0taONIb-OurWxbNQ6ywG"

/// The account every version-history fixture belongs to.
func versionsAccount() throws -> AccountIdentifier {
  try AccountIdentifier(providerDomainIdentifier: versionsDomainIdentifier)
}

/// A revision as `files/list_revisions` returns it. `FileMetadata` decodes the
/// wire format and has no memberwise initializer, so a fixture is JSON.
func revisionMetadata(
  rev: String,
  size: UInt64 = 7212,
  serverModified: String = "2015-05-12T15:51:19Z",
  path: String = "/Homework/Prime_Numbers.txt"
) throws -> FileMetadata {
  let json = """
    {
        ".tag": "file",
        "id": "id:a4ayc_80_OEAAAAAAAAAXw",
        "name": "\(path.split(separator: "/").last ?? "")",
        "path_lower": "\(path.lowercased())",
        "path_display": "\(path)",
        "client_modified": "2015-05-12T15:50:38Z",
        "server_modified": "\(serverModified)",
        "rev": "\(rev)",
        "size": \(size)
    }
    """
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(FileMetadata.self, from: Data(json.utf8))
}

/// A resolver answering with a fixed target, or refusing.
struct StubFileVersionsTargetResolver: FileVersionsTargetResolving {
  var target: FileVersionsTarget?
  var failure: (any Error)?

  func target(for request: FileVersionsRequest) throws -> FileVersionsTarget {
    if let failure { throw failure }
    if let target { return target }
    return FileVersionsTarget(account: request.account, item: try fileIdentifier())
  }
}

/// An account layer answering from a fixed index row and revision list,
/// recording every restore it is asked for and optionally refusing them.
final class StubFileVersionsService: FileVersionsService {
  private let entry: IndexEntryRecord?
  private let listed: [FileMetadata]
  private let revisionsFailure: (any Error)?
  private let restoreFailure: (any Error)?
  private let recorded = Mutex<[Restore]>([])

  /// Every restore the sheet asked for, in the order it asked.
  var restores: [Restore] { recorded.withLock(\.self) }

  init(
    entry: IndexEntryRecord? = nil,
    revisions: [FileMetadata] = [],
    revisionsFailure: (any Error)? = nil,
    restoreFailure: (any Error)? = nil
  ) {
    self.entry = entry
    listed = revisions
    self.revisionsFailure = revisionsFailure
    self.restoreFailure = restoreFailure
  }

  func indexedItem(
    _: DropboxFileIdentifier,
    in _: AccountIdentifier
  ) -> IndexEntryRecord? {
    entry
  }

  func revisions(
    of _: DropboxFileIdentifier,
    in _: AccountIdentifier,
    limit _: UInt
  ) throws -> [FileMetadata] {
    if let revisionsFailure { throw revisionsFailure }
    return listed
  }

  func restore(
    _ path: DropboxPath,
    to revision: FileRevision,
    in account: AccountIdentifier
  ) throws -> FileMetadata {
    recorded.withLock { $0.append(Restore(path: path, revision: revision, account: account)) }
    if let restoreFailure { throw restoreFailure }
    return try revisionMetadata(rev: revision.rawValue)
  }

  /// One restore the sheet asked for.
  struct Restore: Equatable {
    let path: DropboxPath
    let revision: FileRevision
    let account: AccountIdentifier
  }
}

/// Records how a version-history sheet ended.
@MainActor
final class RecordingCompletion {
  private(set) var completionCount = 0
  private(set) var cancellationCount = 0

  var completion: FileVersionsCompletion {
    FileVersionsCompletion(
      complete: { [self] in completionCount += 1 },
      cancel: { [self] in cancellationCount += 1 }
    )
  }
}

/// The Dropbox identifier the fixtures use for the file under test.
func fileIdentifier() throws -> DropboxFileIdentifier {
  try DropboxFileIdentifier(validating: "id:a4ayc_80_OEAAAAAAAAAXw")
}

/// The File Provider item identifier Finder hands a UI extension — opaque, and
/// deliberately nothing like Dropbox's.
let systemItemIdentifier = NSFileProviderItemIdentifier("__fp/fs/docID(4266)")
