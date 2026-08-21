import SwiftUI

/**
 The share sheet: a band naming Zephyr, a band previewing what is being sent,
 and a band holding the destination and the actions.

 The middle band is the only one that changes with the flow's phase, so the
 buttons stay where the reader last saw them.
 */
public struct ShareUploadView: View {
  /**
   The size the sheet opens at, and keeps.

   The share sheet's host reads a size once and holds the extension to it, so
   this covers the tallest thing the sheet shows -- the folder browser -- and
   every shorter state centres itself in the same frame.
   */
  public static let sheetSize = CGSize(width: 440, height: 280)

  @Bindable var model: ShareUploadModel

  public var body: some View {
    VStack(spacing: 0) {
      SheetHeader()
      Divider()
      PhaseContentView(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(.background)
      Divider()
      SheetFooter(model: model)
    }
    .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
    .task { await model.load() }
  }

  /// Shows the share `model` is staging, and sends it where the reader says.
  public init(model: ShareUploadModel) {
    self.model = model
  }
}

/// Whatever the flow's current phase calls for.
private struct PhaseContentView: View {
  @Bindable var model: ShareUploadModel

  var body: some View {
    switch model.phase {
      case .loading:
        ProgressView { Text("Preparing…", bundle: #bundle) }
          .controlSize(.small)
      case let .failed(message):
        Text(message)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      case let .uploading(completed, total):
        UploadProgress(completed: completed, total: total)
      case .finished:
        Label {
          Text("Uploaded.", bundle: #bundle)
        } icon: {
          Image(systemName: "checkmark.circle")
            .foregroundStyle(ZephyrPalette.active)
        }
      case .ready:
        if model.isBrowsingFolders {
          FolderBrowserView(model: model)
        } else {
          ReadyContentView(model: model)
        }
    }
  }
}

/// How far along a multi-file upload is.
private struct UploadProgress: View {
  let completed: Int
  let total: Int

  var body: some View {
    VStack(spacing: 8) {
      ProgressView(value: Double(completed), total: Double(total))
      Text(
        "Uploading \(completed + 1, format: .number) of \(total, format: .number)…",
        bundle: #bundle
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 30)
  }
}

/// The staged files, or the reason there is nothing to send.
private struct ReadyContentView: View {
  @Bindable var model: ShareUploadModel

  var body: some View {
    if model.accounts.isEmpty {
      AdvisoryView(
        LocalizedStringResource(
          "No Dropbox account is linked yet. Open Zephyr to link one first.",
          bundle: #bundle
        ),
        symbol: "person.crop.circle.badge.questionmark"
      )
    } else if model.files.isEmpty {
      AdvisoryView(
        LocalizedStringResource(
          "Nothing here can be uploaded. Folders have to be shared as the files inside them.",
          bundle: #bundle
        ),
        symbol: "folder.badge.questionmark"
      )
    } else {
      VStack(alignment: .leading, spacing: 7) {
        StagedFilesView(files: model.files, providers: model.stagedProviders)
        if !model.skippedNames.isEmpty {
          Text(
            "Skipped \(model.skippedNames.formatted(.list(type: .and, width: .short))) — folders can’t be uploaded.",
            bundle: #bundle
          )
          .font(.caption)
          .foregroundStyle(ZephyrPalette.caution)
        }
        if model.accounts.count > 1 {
          AccountPicker(model: model)
            .padding(.top, 3)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
}

/// The names being sent, capped so a large share does not grow the sheet.
private struct StagedFilesView: View {
  private static let listedNamesLimit = 4
  private static let iconSize: CGFloat = 26

  let files: [URL]
  let providers: [URL: NSItemProvider]

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(files.prefix(Self.listedNamesLimit), id: \.self) { file in
        StagedFileRow(file: file, provider: providers[file], iconSize: Self.iconSize)
      }
      if files.count > Self.listedNamesLimit {
        Text("…and \(files.count - Self.listedNamesLimit, format: .number) more", bundle: #bundle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, Self.iconSize + 8)
      }
    }
  }
}

/**
 One file being sent: what it holds, what it is called, and how big it is.

 The icon opens as the file type's generic icon and gives way, where a picture
 of the file itself can be had, to that picture. The box is the same size either
 way, so nothing on the row moves when the picture lands, and a file nothing can
 draw keeps the icon it opened with.
 */
private struct StagedFileRow: View {
  let file: URL
  let provider: NSItemProvider?
  let iconSize: CGFloat

  @Environment(\.displayScale)
  private var displayScale
  @State private var preview: NSImage?

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: preview ?? NSWorkspace.shared.icon(forFile: file.path))
        .resizable()
        .scaledToFit()
        .frame(width: iconSize, height: iconSize)
        .accessibilityHidden(true)
      Text(file.lastPathComponent)
        .lineLimit(1)
        .truncationMode(.middle)
      if let size = Self.size(of: file) {
        Text(size)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .task {
      preview = await StagedFilePreview.image(
        of: file,
        sharedBy: provider,
        fitting: iconSize,
        scale: displayScale
      )
    }
  }

  /// The file's size as the Finder writes it, or `nil` when it cannot be read.
  private static func size(of file: URL) -> String? {
    guard let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      return nil
    }
    return Int64(bytes).formatted(.byteCount(style: .file))
  }
}

/// Which linked account the files go to, shown only when there is a choice.
private struct AccountPicker: View {
  @Bindable var model: ShareUploadModel

  var body: some View {
    Picker(
      LocalizedStringResource("Account", bundle: #bundle),
      selection: $model.selectedAccountID
    ) {
      ForEach(model.accounts, id: \.accountID) { account in
        Text(account.displayName).tag(Optional(account.accountID))
      }
    }
    .controlSize(.small)
    .fixedSize()
    .accessibilityIdentifier("shareAccountPicker")
  }
}

/// Every folder the account has, filtered as the reader types.
private struct FolderBrowserView: View {
  @Bindable var model: ShareUploadModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField(
          LocalizedStringResource("Filter folders", bundle: #bundle),
          text: $model.folderSearch
        )
        .textFieldStyle(.plain)
        .accessibilityIdentifier("shareFolderFilter")
      }
      .padding(.horizontal, Metrics.sheetGutter)
      .padding(.vertical, 8)
      Divider()
      if model.matchingFolders.isEmpty {
        Text(
          model.folders.isEmpty ? "Still reading your folders…" : "No folder matches.",
          bundle: #bundle
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.matchingFolders, id: \.rawValue) { folder in
              FolderRow(folder: folder, isChosen: folder == model.destination) {
                model.choose(folder)
              }
            }
          }
          .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
      }
    }
  }
}

/// One folder in the browser.
private struct FolderRow: View {
  let folder: DropboxPath
  let isChosen: Bool
  let choose: () -> Void

  /// The folder this one sits in, shown after its name to tell two folders of
  /// the same name apart. A folder at the top of the account has none worth
  /// naming.
  private var parent: DropboxPath? {
    let parent = folder.parent
    return folder.isRoot || parent.isRoot ? nil : parent
  }

  var body: some View {
    Button(action: choose) {
      HStack(spacing: 7) {
        Image(systemName: "folder")
          .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
          .accessibilityHidden(true)
        Text(ShareFolderNaming.label(for: folder))
          .lineLimit(1)
        if let parent {
          PathBreadcrumb(parent)
            .font(.caption)
            .foregroundStyle(
              isChosen ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
            )
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Metrics.sheetGutter)
      .padding(.vertical, 3)
      .contentShape(.rect)
      .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .background(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
    }
    .buttonStyle(.plain)
  }
}

/// The band holding the destination and the actions.
private struct SheetFooter: View {
  @Bindable var model: ShareUploadModel

  var body: some View {
    HStack(spacing: 8) {
      if model.isBrowsingFolders {
        Text("Choose a folder", bundle: #bundle)
          .foregroundStyle(.secondary)
        Spacer()
        Button(LocalizedStringResource("Cancel", bundle: #bundle)) {
          model.cancelBrowsingFolders()
        }
        .keyboardShortcut(.cancelAction)
      } else {
        switch model.phase {
          case .ready where !model.files.isEmpty && !model.accounts.isEmpty:
            Text("Save to:", bundle: #bundle)
            DestinationMenu(model: model)
            Spacer()
            Button(LocalizedStringResource("Cancel", bundle: #bundle)) { model.cancel() }
              .keyboardShortcut(.cancelAction)
            Button(LocalizedStringResource("Save", bundle: #bundle)) {
              Task { await model.upload() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canUpload)
            .accessibilityIdentifier("shareUploadButton")
          case .failed:
            Spacer()
            Button(LocalizedStringResource("Close", bundle: #bundle)) { model.cancel() }
              .keyboardShortcut(.cancelAction)
          default:
            Spacer()
            Button(LocalizedStringResource("Cancel", bundle: #bundle)) { model.cancel() }
              .keyboardShortcut(.cancelAction)
        }
      }
    }
    .padding(.horizontal, Metrics.sheetGutter)
    .padding(.vertical, 11)
  }
}

/// The folders a share can go to without browsing.
private struct DestinationMenu: View {
  @Bindable var model: ShareUploadModel

  var body: some View {
    Menu {
      ForEach(model.offeredFolders, id: \.rawValue) { folder in
        Button {
          model.choose(folder)
        } label: {
          Text(ShareFolderNaming.menuLabel(for: folder))
        }
      }
      Divider()
      Button(LocalizedStringResource("Other Folder…", bundle: #bundle)) {
        model.browseFolders()
      }
    } label: {
      Label {
        Text(ShareFolderNaming.label(for: model.destination))
          .lineLimit(1)
          .truncationMode(.head)
      } icon: {
        Image(systemName: "folder")
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("shareDestinationMenu")
  }
}

/// How a Dropbox folder reads in the sheet's controls.
enum ShareFolderNaming {
  /// The folder's own name, with the account root named for what it is.
  static func label(for folder: DropboxPath) -> String {
    folder.isRoot ? String(localized: "Dropbox", bundle: #bundle) : folder.basename
  }

  /// The name a menu row carries: enough path to tell two same-named folders apart.
  static func menuLabel(for folder: DropboxPath) -> String {
    folder.isRoot ? label(for: folder) : folder.breadcrumb
  }
}

#if DEBUG
  import UniformTypeIdentifiers

  /// Builds the sheet's models on canned accounts and files, one per state the
  /// previews below show.
  @MainActor
  private enum PreviewHelper {
    /// Two files staged, and both accounts to choose between.
    static let ready = model()

    /// A share carrying a folder alongside its files, which the sheet lists as
    /// skipped and sends the rest of.
    static let withSkippedFolder = model(context: SampleShareRequestContext(sharingFolder: true))

    /// The sheet opened straight into the folder browser.
    static let browsingFolders: ShareUploadModel = {
      let sheet = model()
      sheet.browseFolders()
      return sheet
    }()

    /// The sheet with nothing linked to upload to.
    static let noAccounts = model(service: SampleShareUploadService(accounts: []))

    /// A share of nothing but a folder, which leaves nothing to send.
    static let nothingUploadable = model(
      context: SampleShareRequestContext(fileNames: [], sharingFolder: true)
    )

    /// The sheet on an account Dropbox will no longer talk to.
    static let failed = model(service: FailingShareUploadService())

    private static func model(
      context: any ShareRequestContext = SampleShareRequestContext(),
      service: any ShareUploadService = SampleShareUploadService()
    ) -> ShareUploadModel {
      // No defaults at all, so the sheet opens on the account root rather than
      // on wherever this Mac last sent a share.
      ShareUploadModel(context: context, service: service, defaults: nil)
    }
  }

  /// The accounts the previews choose between.
  private enum ShareSample {
    static var accounts: [AccountConfiguration] {
      [
        configuration(id: "dbid:preview-personal", email: "tim@example.com", name: "Tim Morgan"),
        configuration(
          id: "dbid:preview-work",
          email: "tim@work.example.com",
          name: "Tim Morgan (Work)"
        )
      ]
    }

    // The identifiers are fixed literals from this file, so a validation
    // failure is a typo in the sample data.
    private static func configuration(id: String, email: String, name: String)
      -> AccountConfiguration
    {
      AccountConfiguration(
        // swiftlint:disable:next force_try
        accountID: try! AccountIdentifier(validating: id),
        email: email,
        displayName: name,
        // swiftlint:disable:next force_try
        rootNamespaceID: try! NamespaceIdentifier(validating: "1234567890")
      )
    }
  }

  /**
   A share request over documents written for the occasion.

   Each row's icon is a Quick Look render of the staged copy, so the documents
   carry real prose: a file padded out with nothing renders as a page of noise,
   where real lines render as a page of writing.
   */
  @MainActor
  private final class SampleShareRequestContext: ShareRequestContext {
    /// The prose the documents are written out of, repeated until each is the
    /// length a real share would show.
    private static let prose = """
      Agreed the release goes out once the last of the sync issues are closed.
      Tim to write up what changed in the Finder actions and where they live.
      Open question: whether the widget should count folders as well as files.
      """

    /// Where the originals are written, one directory per request.
    private let directory = FileManager.default.temporaryDirectory
      .appending(component: "zephyr-preview-share-\(UUID().uuidString)")

    private var pending: [NSItemProvider] = []

    /**
     The shared items, handed over once and once only.

     A real share request's attachments are consumed once, and so are these:
     the sheet loads itself from its own task, and a second load would stage
     the same documents again onto the ones it is already listing.
     */
    var sharedAttachments: [NSItemProvider] {
      defer { pending = [] }
      return pending
    }

    /**
     Stages a share.

     - Parameters:
       - fileNames: The documents being sent.
       - sharingFolder: Whether a folder is shared alongside them, which
         Dropbox takes one file at a time and so cannot be sent.
     */
    init(
      fileNames: [String] = ["Meeting Notes.txt", "Reading List.txt"],
      sharingFolder: Bool = false
    ) {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      pending = fileNames.compactMap(provider(forDocumentNamed:))
      if sharingFolder, let folder = provider(forFolderNamed: "Receipts") {
        pending.append(folder)
      }
    }

    func completeShare() {}

    func cancelShare() {}

    private func provider(forDocumentNamed name: String) -> NSItemProvider? {
      let url = directory.appending(component: name)
      let text = Array(repeating: Self.prose, count: 40).joined(separator: "\n\n")
      guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
      return NSItemProvider(contentsOf: url)
    }

    private func provider(forFolderNamed name: String) -> NSItemProvider? {
      let url = directory.appending(component: name)
      guard
        (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true))
          != nil
      else { return nil }
      let provider = NSItemProvider()
      provider.suggestedName = name
      provider.registerDataRepresentation(for: .fileURL) { completion in
        completion(url.dataRepresentation, nil)
        return nil
      }
      return provider
    }
  }

  /// The account layer the sheet reads, answering from canned accounts and
  /// folders and uploading nothing.
  private struct SampleShareUploadService: ShareUploadService {
    private static let folderPaths = [
      "/Documents", "/Documents/Invoices", "/Pictures", "/Projects", "/Projects/Zephyr"
    ]

    /// The accounts offered, so a preview can show the sheet with none linked.
    var accounts = ShareSample.accounts

    func shareableAccounts() -> [AccountConfiguration] {
      accounts
    }

    func knownFolders(for _: AccountIdentifier) throws -> [DropboxPath] {
      try Self.folderPaths.map { try DropboxPath(validating: $0) }
    }

    func newestFolders(for account: AccountIdentifier) throws -> [DropboxPath] {
      try knownFolders(for: account)
    }

    func upload(_: URL, to _: DropboxPath, for _: AccountIdentifier) {}
  }

  /// The account layer refusing the share, as it does for an account Dropbox
  /// will no longer talk to.
  private struct FailingShareUploadService: ShareUploadService {
    func shareableAccounts() throws -> [AccountConfiguration] {
      throw AuthenticationFailure.tokenRevoked
    }

    func knownFolders(for _: AccountIdentifier) throws -> [DropboxPath] {
      throw AuthenticationFailure.tokenRevoked
    }

    func newestFolders(for _: AccountIdentifier) throws -> [DropboxPath] {
      throw AuthenticationFailure.tokenRevoked
    }

    func upload(_: URL, to _: DropboxPath, for _: AccountIdentifier) throws {
      throw AuthenticationFailure.tokenRevoked
    }
  }

  #Preview("What is being sent") {
    ShareUploadView(model: PreviewHelper.ready)
  }

  #Preview("A folder among the files") {
    ShareUploadView(model: PreviewHelper.withSkippedFolder)
  }

  #Preview("Choosing a folder") {
    ShareUploadView(model: PreviewHelper.browsingFolders)
  }

  #Preview("No account linked") {
    ShareUploadView(model: PreviewHelper.noAccounts)
  }

  #Preview("Nothing that can be sent") {
    ShareUploadView(model: PreviewHelper.nothingUploadable)
  }

  #Preview("Dropbox refused the account") {
    ShareUploadView(model: PreviewHelper.failed)
  }
#endif
