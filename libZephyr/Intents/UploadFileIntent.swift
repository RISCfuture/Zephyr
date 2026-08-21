import AppIntents
import Foundation

/// Sends a file from a shortcut to a folder in Dropbox.
struct UploadFileIntent: AppIntent {
  /// The name Shortcuts lists this action under.
  static let title = LocalizedStringResource("Upload to Dropbox", bundle: .libZephyr)

  // periphery:ignore - App Intents reads this out of the extracted metadata; it has a
  // default, so nothing in Zephyr calls it and the dead-code check can't see the system.
  /// What the action does, shown beneath its name.
  static let description = IntentDescription(
    LocalizedStringResource("Sends a file to a folder in your Dropbox.", bundle: .libZephyr)
  )

  static let supportedModes: IntentModes = .background

  /// The file to send.
  @Parameter(title: LocalizedStringResource("File", bundle: .libZephyr))
  var file: IntentFile

  /// Where to put it.
  @Parameter(
    title: LocalizedStringResource("Folder", bundle: .libZephyr),
    default: "/",
    optionsProvider: DropboxFolderOptions()
  )
  var folder: String

  /// Whether to replace a file already at that name.
  ///
  /// Off by default, and off means Dropbox renames rather than replaces —
  /// the same choice the share sheet makes, because a shortcut that ran twice
  /// should not quietly destroy what the first run sent.
  @Parameter(title: LocalizedStringResource("Replace Existing File", bundle: .libZephyr))
  var overwrite: Bool

  /// The account to upload to, or nothing to take the only one linked.
  @Parameter(title: LocalizedStringResource("Account", bundle: .libZephyr))
  var account: AccountEntity?

  init() {}

  /**
   Runs `work` against the file's bytes on disk.

   An `IntentFile` may be a file somewhere or may be bytes held in memory.
   Where there is a file, that file is handed straight over: uploading reads
   it in pieces, and materializing a video in memory to hand it back a piece
   at a time would undo that. Where there is not, the bytes are written out
   once and removed afterwards.
   */
  private static func withLocalCopy<Result>(
    of file: IntentFile,
    _ work: (URL) async throws -> Result
  ) async throws -> Result {
    if let url = file.fileURL {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      return try await work(url)
    }
    let staged = FileManager.default.temporaryDirectory
      .appending(component: "zephyr-intent-\(UUID().uuidString)")
    try file.data.write(to: staged, options: .atomic)
    defer { try? FileManager.default.removeItem(at: staged) }
    return try await work(staged)
  }

  /// Uploads the file and answers with the item Dropbox stored.
  func perform() async throws -> some IntentResult & ReturnsValue<DropboxItemEntity>
    & ProvidesDialog
  {
    let uploaded = try await withIntentFailures {
      let service = SharedAccountService.shared
      let linked = try await service.scriptableAccounts()
      guard let accountID = try IntentAccounts.resolve(account, among: linked) else {
        throw $account.needsValueError(IntentAccounts.accountPrompt)
      }
      let configuration = try await service.configuration(for: accountID)
      let destination = try DropboxPath(userTyped: folder).appending(file.filename)
      let metadata = try await Self.withLocalCopy(of: file) { localURL in
        try await service.upload(
          localURL,
          to: destination,
          mode: overwrite ? .overwrite : .add,
          in: accountID
        )
      }
      return DropboxItemEntity(metadata, in: configuration)
    }
    return .result(
      value: uploaded,
      dialog: IntentDialog(
        LocalizedStringResource("Uploaded “\(uploaded.name)” to Dropbox.", bundle: .libZephyr)
      )
    )
  }
}

/// The folders a shortcut may upload into: every one the index knows.
struct DropboxFolderOptions: DynamicOptionsProvider {
  @IntentParameterDependency<UploadFileIntent>(\.$account)
  private var uploading

  init() {}

  /// The chosen account's folders, or nothing when several accounts are
  /// linked and none has been chosen — a list mixing two Dropboxes would
  /// offer paths that mean different places.
  func results() async throws -> [String] {
    let service = SharedAccountService.shared
    let linked = try await service.scriptableAccounts()
    guard let account = try IntentAccounts.resolve(uploading?.account, among: linked)
    else { return [] }
    return try await service.folderPaths(in: account).map(\.displayPath)
  }
}
