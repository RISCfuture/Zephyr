import Foundation

/**
 What the share flow needs from the account layer: the accounts it may upload
 with, the folders it may upload into, and a way to send one file.

 The flow reaches Dropbox through this and nothing else, so its tests can stand
 in for the network without standing in for the flow.
 */
public protocol ShareUploadService: Sendable {
  /// The linked accounts the sheet offers, in the order it lists them.
  func shareableAccounts() async throws -> [AccountConfiguration]

  /**
   The folders already known for `account`, answered from local state.

   The sheet opens on these, so this must not reach the network.
   */
  func knownFolders(for account: AccountIdentifier) async throws -> [DropboxPath]

  /**
   The account's top-level folders, read from Dropbox itself.

   Only the top level: walking a whole account costs four round trips and some
   twenty seconds on a 7,000-item Dropbox, which is longer than the sheet is
   open. The index already holds everything the sync engine has seen, so this
   only has to catch a folder made somewhere else a moment ago.
   */
  func newestFolders(for account: AccountIdentifier) async throws -> [DropboxPath]

  /// Uploads one file to `path` under `account`.
  func upload(_ file: URL, to path: DropboxPath, for account: AccountIdentifier) async throws
}

/**
 The share flow's live account layer, backed by ``AccountManager``.

 A session is opened once per account and held for the whole share, so sending
 several files refreshes the access token once rather than once per file.
 */
public actor LiveShareUploadService: ShareUploadService {
  private let manager: AccountManager
  private var sessions: [AccountIdentifier: AccountSession] = [:]

  public init(manager: AccountManager) {
    self.manager = manager
  }

  public func shareableAccounts() async throws -> [AccountConfiguration] {
    var configurations: [AccountConfiguration] = []
    for account in try await manager.authenticatableAccounts() {
      configurations.append(try await manager.configuration(for: account))
    }
    return configurations.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  public func knownFolders(for account: AccountIdentifier) async throws -> [DropboxPath] {
    let index = try await session(for: account).openIndex(mode: .readOnly)
    return try await index.folderPaths()
  }

  public func newestFolders(for account: AccountIdentifier) async throws -> [DropboxPath] {
    let listing = try await session(for: account).listFolder(.root)
    var paths: [DropboxPath] = []
    for try await item in listing {
      guard case .folder = item, let path = item.pathDisplay else { continue }
      paths.append(path)
    }
    return paths
  }

  public func upload(
    _ file: URL,
    to path: DropboxPath,
    for account: AccountIdentifier
  ) async throws {
    _ = try await session(for: account).upload(file, to: path, mode: .add)
  }

  private func session(for account: AccountIdentifier) async throws -> AccountSession {
    if let existing = sessions[account] { return existing }
    let session = try await manager.session(for: account)
    sessions[account] = session
    return session
  }
}
