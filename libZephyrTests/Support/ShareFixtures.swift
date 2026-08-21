import Foundation
import Synchronization

@testable import libZephyr

/// A share request over a fixed set of attachments, recording how it ended.
@MainActor
final class RecordingShareRequestContext: ShareRequestContext {
  let sharedAttachments: [NSItemProvider]

  private(set) var completionCount = 0
  private(set) var cancellationCount = 0

  init(attachments: [NSItemProvider] = []) {
    sharedAttachments = attachments
  }

  /// A request over item providers for each of `urls`, in order.
  convenience init(sharing urls: [URL]) {
    self.init(attachments: urls.compactMap { NSItemProvider(contentsOf: $0) })
  }

  func completeShare() { completionCount += 1 }
  func cancelShare() { cancellationCount += 1 }
}

/// An account layer answering from fixed lists, recording every upload it is
/// asked for and optionally refusing them.
final class StubShareUploadService: ShareUploadService {
  private let accounts: [AccountConfiguration]
  private let indexedFolders: [DropboxPath]
  private let dropboxFolders: [DropboxPath]?
  private let refreshFails: Bool
  private let accountsFailure: (any Error)?
  private let uploadFailure: (any Error)?
  private let recorded = Mutex<[Request]>([])

  /// Every upload the flow asked for, in the order it asked.
  var requests: [Request] { recorded.withLock(\.self) }

  /**
   - Parameters:
     - indexed: What the local index answers with.
     - fromDropbox: The top-level folders the refresh behind the sheet answers
       with; omitted, it answers with nothing new.
     - refreshFails: Makes the refresh throw, which must leave `indexed` standing.
   */
  init(
    accounts: [AccountConfiguration] = [],
    indexed: [DropboxPath] = [],
    fromDropbox: [DropboxPath]? = nil,
    refreshFails: Bool = false,
    accountsFailure: (any Error)? = nil,
    uploadFailure: (any Error)? = nil
  ) {
    self.accounts = accounts
    indexedFolders = indexed
    dropboxFolders = fromDropbox
    self.refreshFails = refreshFails
    self.accountsFailure = accountsFailure
    self.uploadFailure = uploadFailure
  }

  func shareableAccounts() throws -> [AccountConfiguration] {
    if let accountsFailure { throw accountsFailure }
    return accounts
  }

  func knownFolders(for _: AccountIdentifier) -> [DropboxPath] { indexedFolders }

  func newestFolders(for _: AccountIdentifier) throws -> [DropboxPath] {
    if refreshFails { throw EngineFailure.notLinked }
    return dropboxFolders ?? []
  }

  func upload(_ file: URL, to path: DropboxPath, for account: AccountIdentifier) throws {
    recorded.withLock {
      $0.append(Request(fileName: file.lastPathComponent, path: path, account: account))
    }
    if let uploadFailure { throw uploadFailure }
  }

  /// One upload the flow asked for.
  struct Request: Equatable {
    let fileName: String
    let path: DropboxPath
    let account: AccountIdentifier
  }
}

/// A linked account, named for whatever the test needs to tell apart.
func shareAccount(
  _ displayName: String,
  id: String = "dbid:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
) throws -> AccountConfiguration {
  AccountConfiguration(
    accountID: try AccountIdentifier(validating: id),
    email: "\(displayName.lowercased())@example.com",
    displayName: displayName,
    rootNamespaceID: try NamespaceIdentifier(validating: "1234567890")
  )
}

/// Where the folders one account's shares have gone to are remembered.
func rememberedFoldersKey(for account: AccountConfiguration) -> String {
  "shareRecentFolders-\(account.accountID.rawValue)"
}

/// Dropbox folder paths from their display strings.
func folders(_ paths: String...) throws -> [DropboxPath] {
  try paths.map { try DropboxPath(validating: $0) }
}

/// A fresh temporary directory holding files named by `names`, each with
/// distinguishable contents.
func makeSharedFiles(named names: [String]) throws -> (directory: URL, urls: [URL]) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("zephyr-share-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let urls = try names.map { name -> URL in
    let url = directory.appendingPathComponent(name)
    try Data("contents of \(name)".utf8).write(to: url)
    return url
  }
  return (directory, urls)
}

/// A `UserDefaults` over a suite no other test shares, emptied when `body` returns.
func withTemporaryDefaults<Result>(
  _ body: (UserDefaults) async throws -> Result
) async rethrows -> Result {
  let suiteName = "zephyr-share-tests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  return try await body(defaults)
}
