import FileProvider
import Foundation

/**
 What a Finder version-history action was invoked on, as the system describes
 it: the account whose domain the action came from, and the system's own
 identifier for the file.

 The identifier here is deliberately not Dropbox's. A File Provider *UI*
 extension is handed an opaque token — `__fp/fs/docID(4266)` — where the File
 Provider extension's `performAction` is handed the `id:` string Zephyr stores.
 Turning one into the other is a round trip through the system, so it happens
 in ``FileVersionsTargetResolving`` rather than here, and what is left in this
 initializer is the part worth testing.
 */
public struct FileVersionsRequest: Sendable, Equatable {
  /// The account holding the file.
  public let account: AccountIdentifier

  /// The system's identifier for the file, awaiting resolution.
  public let identifier: NSFileProviderItemIdentifier

  /**
   Reads what `prepare(forAction:itemIdentifiers:)` was handed.

   - Parameters:
     - domainIdentifier: The extension context's domain, in the form
       ``AccountIdentifier/providerDomainIdentifier``.
     - itemIdentifiers: The items the action was invoked on. The action's
       activation rule admits exactly one, and anything else is refused here
       rather than acted on arbitrarily.
   */
  public init(
    domainIdentifier: String?,
    itemIdentifiers: [NSFileProviderItemIdentifier]
  ) throws {
    guard itemIdentifiers.count == 1, let identifier = itemIdentifiers.first else {
      throw FileVersionsFailure.notOneFile
    }
    guard let domainIdentifier,
      let account = try? AccountIdentifier(providerDomainIdentifier: domainIdentifier)
    else {
      throw FileVersionsFailure.noAccount
    }
    self.account = account
    self.identifier = identifier
  }
}

/// The file a version-history sheet is about, in the terms Dropbox uses.
public struct FileVersionsTarget: Sendable, Equatable {
  /// The account holding the file.
  public let account: AccountIdentifier

  /// Dropbox's identifier for the file, which follows it through renames.
  public let item: DropboxFileIdentifier

  /// Names a file in an account.
  public init(account: AccountIdentifier, item: DropboxFileIdentifier) {
    self.account = account
    self.item = item
  }
}

/// Turns the system's identifier for a file into Dropbox's.
public protocol FileVersionsTargetResolving: Sendable {
  /// The Dropbox file a request names.
  func target(for request: FileVersionsRequest) async throws -> FileVersionsTarget
}

/**
 The live resolver, which asks the system.

 Two hops, because there is no direct translation: the item identifier becomes
 the file's user-visible URL, and the URL becomes the identifier the provider
 issued. The domain that comes back is checked against the one the action
 arrived from, so a file dragged out of a Zephyr domain between the menu
 opening and the sheet appearing is refused rather than acted on in the wrong
 account.
 */
public struct SystemFileVersionsTargetResolver: FileVersionsTargetResolving {
  /// Creates a resolver.
  public init() {}

  public func target(for request: FileVersionsRequest) async throws -> FileVersionsTarget {
    let domainIdentifier = request.account.providerDomainIdentifier
    let domains = try await NSFileProviderManager.domains()
    guard let domain = domains.first(where: { $0.identifier.rawValue == domainIdentifier }),
      let manager = NSFileProviderManager(for: domain)
    else {
      throw FileVersionsFailure.noAccount
    }

    let url = try await manager.getUserVisibleURL(for: request.identifier)
    let (resolved, resolvedDomain) =
      try await NSFileProviderManager
      .identifierForUserVisibleFile(at: url)
    guard resolvedDomain.rawValue == domainIdentifier,
      let item = try? DropboxFileIdentifier(validating: resolved.rawValue)
    else {
      throw FileVersionsFailure.fileUnavailable
    }
    return FileVersionsTarget(account: request.account, item: item)
  }
}
