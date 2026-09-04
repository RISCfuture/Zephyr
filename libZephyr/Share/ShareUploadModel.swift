public import Foundation
import Observation
import UniformTypeIdentifiers

/**
 The share flow's state: the files handed over by the share sheet, the linked
 accounts, the folder they land in, and the upload's progress.
 */
@MainActor
@Observable
public final class ShareUploadModel {
  /**
   The group-defaults key prefix remembering the folders shares have gone to.

   Per account, because a path is only meaningful inside the Dropbox it was
   chosen in. `files/upload` creates the parents a path names rather than
   refusing it, so one shared list would not merely offer the wrong folder —
   it would build it, in an account the user never chose it for.
   */
  private static let recentFoldersKeyPrefix = "shareRecentFolders-"
  /// How many folders the destination menu offers before browsing.
  static let maximumRecentFolders = 5

  /// The linked accounts the extension can upload with.
  public private(set) var accounts: [AccountConfiguration] = []
  /// The account uploads go to.
  public var selectedAccountID: AccountIdentifier? {
    didSet {
      guard selectedAccountID != oldValue else { return }
      adoptRememberedDestination()
      reloadFolders()
    }
  }
  /// The folder uploads land in.
  public private(set) var destination: DropboxPath
  /// The folders shares have gone to before, newest first.
  public private(set) var recentFolders: [DropboxPath]
  /// Every folder the selected account is known to have.
  public private(set) var folders: [DropboxPath] = []
  /// Whether the sheet is showing the folder browser rather than the files.
  public private(set) var isBrowsingFolders = false
  /// What the browser's search field holds.
  public var folderSearch = ""
  /// The staged files awaiting upload.
  public private(set) var files: [URL] = []
  /// The shared item each staged file was copied from, so the sheet can ask
  /// the sharing app what the file looks like without staging it again.
  private(set) var stagedProviders: [URL: NSItemProvider] = [:]
  /// Shared items that could not be staged (folders, unreadable items).
  public private(set) var skippedNames: [String] = []
  /// Where the flow stands.
  public private(set) var phase = Phase.loading

  private let context: any ShareRequestContext
  private let service: any ShareUploadService
  private let defaults: UserDefaults?
  private var refreshTask: Task<Void, Never>?
  private let stagingDirectory = FileManager.default.temporaryDirectory
    .appending(component: "zephyr-share-\(UUID().uuidString)")

  /// Whether an upload can start.
  public var canUpload: Bool {
    phase == .ready && !files.isEmpty && selectedAccountID != nil
  }

  /// The folders the browser lists for what has been typed into its search field.
  public var matchingFolders: [DropboxPath] {
    let needle = folderSearch.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return folders }
    return folders.filter { $0.displayPath.localizedCaseInsensitiveContains(needle) }
  }

  /// The folders the destination menu offers directly, newest use first.
  public var offeredFolders: [DropboxPath] {
    var offered = recentFolders
    if !offered.contains(destination) { offered.insert(destination, at: 0) }
    if !offered.contains(.root) { offered.append(.root) }
    return Array(offered.prefix(Self.maximumRecentFolders + 1))
  }

  /**
   Creates the flow over one share request.

   - Parameters:
     - context: The share sheet's request — the shared items, and how the sheet
       is dismissed.
     - service: The account layer uploads go through.
     - defaults: Where the folders shares have gone to are remembered.
   */
  public init(
    context: any ShareRequestContext,
    service: any ShareUploadService,
    defaults: UserDefaults? = UserDefaults(suiteName: ZephyrEnvironment.appGroupIdentifier)
  ) {
    self.context = context
    self.service = service
    self.defaults = defaults
    // The account is not known until ``load()`` has asked, and what is
    // remembered belongs to an account, so the flow starts at the one folder
    // every Dropbox has.
    recentFolders = []
    destination = .root
  }

  /// Reads the folders remembered for an account, dropping any that no longer
  /// parse.
  private static func storedRecentFolders(
    for account: AccountIdentifier?,
    in defaults: UserDefaults?
  ) -> [DropboxPath] {
    guard let account else { return [] }
    return (defaults?.stringArray(forKey: recentFoldersKey(for: account)) ?? [])
      .compactMap { try? DropboxPath(validating: $0) }
  }

  private static func recentFoldersKey(for account: AccountIdentifier) -> String {
    recentFoldersKeyPrefix + account.rawValue
  }

  /// Copies one shared item into `directory`. A shared file URL keeps the
  /// original filename, so it goes first; the provider's file representation
  /// is the fallback when the URL is absent or unreadable.
  private static func stage(_ provider: NSItemProvider, into directory: URL) async throws -> URL {
    if let url = await sharedFileURL(of: provider) {
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
        throw StagingRefusal.folder(name: url.lastPathComponent)
      }
      if let staged = try? copy(url, into: directory) { return staged }
    }
    guard offersItsOwnContents(provider) else { throw StagingRefusal.noContents }
    return try await stageFileRepresentation(of: provider, into: directory)
  }

  /// The URL of the shared item itself, or `nil` when the provider offers none
  /// that can be read.
  private static func sharedFileURL(of provider: NSItemProvider) async -> URL? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
      let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
    else { return nil }
    return item as? URL
      ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
  }

  /**
   Whether the provider offers the item's contents rather than only a pointer
   to it.

   `public.file-url` conforms to `public.data`, so asking for data conformance
   alone accepts the URL as though it were the file and stages a document
   holding the URL's own bytes.
   */
  private static func offersItsOwnContents(_ provider: NSItemProvider) -> Bool {
    provider.registeredTypeIdentifiers
      .compactMap(UTType.init)
      .contains { $0.conforms(to: .data) && !$0.conforms(to: .url) }
  }

  private static func copy(_ url: URL, into directory: URL) throws -> URL {
    let destination = directory.appending(component: url.lastPathComponent)
    try FileManager.default.copyItem(at: url, to: destination)
    return destination
  }

  private static func stageFileRepresentation(
    of provider: NSItemProvider,
    into directory: URL
  ) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
        // The system deletes its copy when this handler returns, so the
        // move to the staging directory happens inside it.
        do {
          guard let url else { throw error ?? CocoaError(.fileNoSuchFile) }
          let destination = directory.appending(component: url.lastPathComponent)
          try FileManager.default.copyItem(at: url, to: destination)
          continuation.resume(returning: destination)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// How a shared item is named once it has been skipped: whatever refusing it
  /// revealed, else whatever the sharing app suggested.
  private static func name(of provider: NSItemProvider, refusedBy error: any Error) -> String {
    (error as? StagingRefusal)?.name
      ?? provider.suggestedName
      ?? String(
        localized: "an item",
        bundle: #bundle,
        comment: "Stands in for a skipped share with no known name"
      )
  }

  /// The indexed folders, plus any Dropbox has that the index has not seen.
  private static func merged(
    _ indexed: [DropboxPath],
    adding newest: [DropboxPath]
  ) -> [DropboxPath] {
    var seen = Set(indexed.map(\.normalized))
    let unseen = newest.filter { seen.insert($0.normalized).inserted }
    guard !unseen.isEmpty else { return indexed }
    return (indexed + unseen).sorted {
      $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending
    }
  }

  /// Loads the linked accounts and stages the shared files.
  public func load() async {
    do {
      accounts = try await service.shareableAccounts()
      selectedAccountID = accounts.first?.accountID
      try await stageAttachments()
      phase = .ready
    } catch {
      phase = .failed(ErrorSentence.describe(error))
    }
  }

  /// Opens the folder browser.
  public func browseFolders() {
    folderSearch = ""
    isBrowsingFolders = true
  }

  /// Leaves the folder browser without changing the destination.
  public func cancelBrowsingFolders() {
    isBrowsingFolders = false
  }

  /// Sends uploads to `folder`, leaving the browser if it is open.
  public func choose(_ folder: DropboxPath) {
    destination = folder
    isBrowsingFolders = false
  }

  /// Uploads every staged file, then completes the extension request.
  public func upload() async {
    guard let selectedAccountID else { return }
    do {
      rememberDestination()
      for (index, file) in files.enumerated() {
        phase = .uploading(completed: index, total: files.count)
        try await service.upload(
          file,
          to: try destination.appending(file.lastPathComponent),
          for: selectedAccountID
        )
      }
      phase = .finished
      cleanUpStaging()
      context.completeShare()
    } catch {
      phase = .failed(ErrorSentence.describe(error))
    }
  }

  /// Abandons the share.
  public func cancel() {
    refreshTask?.cancel()
    cleanUpStaging()
    context.cancelShare()
  }

  private func stageAttachments() async throws {
    try FileManager.default.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true
    )
    for (index, provider) in context.sharedAttachments.enumerated() {
      let itemDirectory = stagingDirectory.appending(component: String(index))
      try FileManager.default.createDirectory(
        at: itemDirectory,
        withIntermediateDirectories: true
      )
      do {
        let staged = try await Self.stage(provider, into: itemDirectory)
        files.append(staged)
        stagedProviders[staged] = provider
      } catch {
        skippedNames.append(Self.name(of: provider, refusedBy: error))
      }
    }
  }

  /**
   Fills the folder list for the selected account.

   What is already indexed answers straight away; Dropbox is asked behind the
   open sheet for anything the index has not seen yet. A refresh that fails
   changes nothing -- the sheet is usable on what the index knew.
   */
  private func reloadFolders() {
    refreshTask?.cancel()
    folders = []
    guard let account = selectedAccountID else { return }
    refreshTask = Task { [service] in
      if let known = try? await service.knownFolders(for: account), !Task.isCancelled {
        folders = known
      }
      guard let newest = try? await service.newestFolders(for: account), !Task.isCancelled
      else { return }
      folders = Self.merged(folders, adding: newest)
    }
  }

  /// Awaits the folder load and the refresh behind it.
  func settleFolders() async {
    await refreshTask?.value
  }

  /**
   Takes up the destination remembered for the selected account.

   Switching accounts leaves the destination behind with the account it was
   chosen in: a folder is a place in one Dropbox, and carrying its path across
   would upload into a path of the same name that the other account may not
   have — and would then have.
   */
  private func adoptRememberedDestination() {
    recentFolders = Self.storedRecentFolders(for: selectedAccountID, in: defaults)
    destination = recentFolders.first ?? .root
  }

  private func rememberDestination() {
    guard let selectedAccountID else { return }
    var remembered = recentFolders.filter { $0 != destination }
    remembered.insert(destination, at: 0)
    recentFolders = Array(remembered.prefix(Self.maximumRecentFolders))
    defaults?.set(
      recentFolders.map(\.rawValue),
      forKey: Self.recentFoldersKey(for: selectedAccountID)
    )
  }

  private func cleanUpStaging() {
    try? FileManager.default.removeItem(at: stagingDirectory)
  }

  /**
   Why a shared item could not be staged.

   Never surfaced as an error: the sheet lists the item under
   ``skippedNames`` and sends the rest.
   */
  private enum StagingRefusal: Error {
    /// A folder was shared; Dropbox takes one file at a time.
    case folder(name: String)
    /// The provider offers only a pointer to the item, not the item.
    case noContents

    /// The item's name, where refusing it revealed one.
    var name: String? {
      switch self {
        case let .folder(name): name
        case .noContents: nil
      }
    }
  }

  /// Where the flow stands, driving which controls the sheet shows.
  public enum Phase: Equatable {
    case loading
    case ready
    case uploading(completed: Int, total: Int)
    case finished
    case failed(String)
  }
}
