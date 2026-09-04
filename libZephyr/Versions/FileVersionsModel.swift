public import FileProvider
import Foundation
import Observation

/**
 The version-history sheet's state: which file it is about, the revisions
 Dropbox kept of it, and how a restore is going.

 Unlike the share sheet, the subject arrives after the view does — a File
 Provider UI extension loads its view first and is told what the action was
 invoked on afterwards — so the file is handed over by ``begin(inDomain:itemIdentifiers:)``
 rather than by the initializer.
 */
@MainActor
@Observable
public final class FileVersionsModel {
  /// Where the sheet stands.
  public private(set) var phase = Phase.loading
  /// The file's name, once known.
  public private(set) var fileName = ""
  /// The file's Dropbox path, once known.
  public private(set) var path: DropboxPath?
  /// The stored revisions, most recent first.
  public private(set) var revisions: [Revision] = []
  /// Which revision the reader has chosen.
  public var selection: FileRevision?
  /// Whether the sheet is asking the reader to confirm a restore.
  public var isConfirmingRestore = false

  private let service: any FileVersionsService
  private let resolver: any FileVersionsTargetResolving
  private let completion: FileVersionsCompletion
  private var target: FileVersionsTarget?

  /// Whether a restore can start: a revision is chosen, and it is not the one
  /// the file is already at.
  public var canRestore: Bool {
    guard phase == .listing, let selection else { return false }
    return revisions.first { $0.id == selection }?.isCurrent == false
  }

  /**
   Creates the sheet's state.

   - Parameters:
     - service: The account layer the revisions come from.
     - resolver: How the system's identifier for the file becomes Dropbox's.
     - completion: How the sheet ends.
   */
  public init(
    service: any FileVersionsService,
    resolver: any FileVersionsTargetResolving = SystemFileVersionsTargetResolver(),
    completion: FileVersionsCompletion
  ) {
    self.service = service
    self.resolver = resolver
    self.completion = completion
  }

  /// Takes the file the action was invoked on and lists its revisions.
  public func begin(
    inDomain domainIdentifier: String?,
    itemIdentifiers: [NSFileProviderItemIdentifier]
  ) async {
    do {
      let request = try FileVersionsRequest(
        domainIdentifier: domainIdentifier,
        itemIdentifiers: itemIdentifiers
      )
      let target = try await resolver.target(for: request)
      self.target = target
      try await load(target)
    } catch {
      fail(with: error)
    }
  }

  /// Shows a failure the system reported rather than one the sheet caused —
  /// the authentication error `prepare(forError:)` delivers.
  public func show(_ error: any Error) {
    fail(with: error)
  }

  /// Puts the file back to the chosen revision.
  public func restore() async {
    guard let target, let path, let selection else { return }
    phase = .restoring
    do {
      _ = try await service.restore(path, to: selection, in: target.account)
      phase = .restored
    } catch {
      fail(with: error)
    }
  }

  /// Ends the request, having done what the reader asked.
  public func finish() {
    completion.complete()
  }

  /// Abandons the request.
  public func cancel() {
    completion.cancel()
  }

  private func load(_ target: FileVersionsTarget) async throws {
    let entry = try await service.indexedItem(target.item, in: target.account)
    fileName = entry?.name ?? ""
    path = entry?.pathCased

    let listed = try await service.revisions(
      of: target.item,
      in: target.account,
      limit: AccountSession.defaultRevisionLimit
    )
    guard !listed.isEmpty else {
      phase = .empty
      return
    }
    // The index knows which revision the file is at, which is a better answer
    // than "the newest one Dropbox listed" — a file changed elsewhere and not
    // yet synced here is at neither.
    let current = entry?.revision
    revisions = listed.map {
      Revision(
        id: $0.rev,
        recorded: $0.serverModified,
        size: Measurement(value: Double($0.size), unit: .bytes),
        isCurrent: $0.rev == current
      )
    }
    selection = revisions.first { !$0.isCurrent }?.id
    phase = .listing
  }

  private func fail(with error: any Error) {
    phase = .failed(ErrorSentence.describe(error, includingRecovery: true))
  }

  /// One stored revision, as the sheet lists it.
  public struct Revision: Identifiable, Sendable, Equatable {
    /// Dropbox's identifier for the revision, which is also its identity here.
    public let id: FileRevision
    /// When Dropbox recorded it.
    public let recorded: Date
    /// The file's size at that revision.
    public let size: Measurement<UnitInformationStorage>
    /// Whether this is the revision the file is at now.
    public let isCurrent: Bool
  }

  /// Where the sheet stands.
  public enum Phase: Equatable {
    /// Resolving the file and asking Dropbox what it has.
    case loading
    /// Revisions listed, waiting for a choice.
    case listing
    /// Dropbox kept no earlier version of this file.
    case empty
    /// A restore is in flight.
    case restoring
    /// The file was put back.
    case restored
    /// Something went wrong, described in the reader's words.
    case failed(String)
  }
}

/// How a version-history sheet ends, which is the host's business rather than
/// the sheet's: a File Provider UI extension completes or cancels its request,
/// and a window would close itself.
public struct FileVersionsCompletion: Sendable {
  /// Ends the request successfully.
  public let complete: @MainActor @Sendable () -> Void
  /// Abandons the request.
  public let cancel: @MainActor @Sendable () -> Void

  /// Creates a pair of endings.
  public init(
    complete: @escaping @MainActor @Sendable () -> Void,
    cancel: @escaping @MainActor @Sendable () -> Void
  ) {
    self.complete = complete
    self.cancel = cancel
  }
}
