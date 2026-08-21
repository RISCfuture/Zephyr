import Foundation

/**
 What the sync index says about one account.

 The same reading `zephyr status` prints, minus everything that needs a
 credential or the network: it comes out of the index alone, so it is
 answerable for an account whose authorization has lapsed, and on a Mac that
 has not been online since it was last read.
 */
public struct SyncStatus: Sendable, Equatable {
  /// The reading for an account that has no index yet.
  public static let notIndexed = Self(
    indexState: .missing,
    files: 0,
    folders: 0,
    syncIssueCount: 0,
    accountFailure: nil
  )

  /// How far the index has got.
  public let indexState: IndexState

  /// Files the index holds.
  public let files: UInt

  /// Folders the index holds.
  public let folders: UInt

  /// Items Dropbox and this Mac could not agree on.
  public let syncIssueCount: UInt

  /// What stopped the whole account, or `nil` while it syncs.
  public let accountFailure: EngineErrorRecord?

  /// Reads an account's state from its index.
  public init(reading index: SyncIndexStore) async throws {
    let counts = try await index.counts()
    let finished = try await index.didFinishInitialIndex()
    indexState = finished ? .complete : .indexing
    files = counts.files
    folders = counts.folders
    syncIssueCount = UInt(try await index.syncErrors().count)
    accountFailure = try await index.engineError()
  }

  private init(
    indexState: IndexState,
    files: UInt,
    folders: UInt,
    syncIssueCount: UInt,
    accountFailure: EngineErrorRecord?
  ) {
    self.indexState = indexState
    self.files = files
    self.folders = folders
    self.syncIssueCount = syncIssueCount
    self.accountFailure = accountFailure
  }

  /// How far the sync index has got.
  public enum IndexState: String, Sendable, Equatable {
    /// No index has been built yet.
    case missing

    /// The initial recursive listing is still running.
    case indexing

    /// The index mirrors the account and follows the change feed.
    case complete
  }
}
