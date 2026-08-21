#if DEBUG
  import AppKit
  import FileProvider
  import SwiftUI
  import WidgetKit
  import libZephyr

  /**
   Hosts one design-layer surface on its own, so the screenshot suite can
   photograph something the app itself never puts on screen.

   The version-history sheet and the share sheet belong to app extensions —
   Finder hosts one, whichever app is sharing hosts the other — and neither host
   can be launched by a UI test, staged against a plain backdrop, or pinned to
   an appearance. Both extensions set their view as the whole of their sheet, so
   what is captured here is what ships: the same view at the same size, drawn by
   the same framework, on the same backdrop as every other capture.

   The widget layouts are here for a different reason. WidgetKit draws the tile
   around them, and nothing outside a widget extension can ask it to, so
   ``WidgetTile`` stands in for the part WidgetKit would have drawn.

   Every subject is fed from canned data, as ``PreviewHelper`` feeds the app's
   own windows: no keychain, no domain, no network.
   */
  @MainActor
  enum DesignGallery {
    /// The gallery window's title. It is never drawn — the window is stripped
    /// back to its content — but it is how ``ScreenshotStaging`` finds the
    /// window and how a test frames a capture on it.
    static let windowTitle = "Design"

    /**
     The accounts the widget subjects read: the same two the accounts window and
     the menu-bar panel are captured on, with the same figures.

     Both were last busy hours ago rather than a minute ago, which the other
     captures use. The widget writes that out as a live relative date — "2 hours
     ago" — and a value a minute old crosses into "2 minutes ago" while the
     window is on screen, so the light capture and the dark one, taken minutes
     apart in launches of their own, would not read the same. Hours hold still
     for an hour.
     */
    private static var widgetAccounts: [SyncStatusSnapshot.AccountStatus] {
      zip(
        PreviewHelper.sampleAccounts,
        [
          (files: UInt(6754), folders: UInt(593), latestChange: TimeInterval(-3600 * 2)),
          (files: UInt(1204), folders: UInt(88), latestChange: TimeInterval(-3600 * 5))
        ]
      )
      .map { account, figures in
        SyncStatusSnapshot.AccountStatus(
          id: account.accountID.rawValue,
          displayName: account.displayName,
          files: figures.files,
          folders: figures.folders,
          syncErrorCount: 0,
          latestChange: Date(timeIntervalSinceNow: figures.latestChange)
        )
      }
    }

    /// Whatever `subject` calls for, at the size its host would give it and
    /// inside the shape its host would draw around it.
    @ViewBuilder
    static func view(for subject: Subject) -> some View {
      switch subject {
        case .fileVersions: FileVersionsSubjectView()
        case .shareUpload: ShareUploadSubjectView()
        case .widgetSmall: WidgetSubjectView(family: .systemSmall)
        case .widgetMedium: WidgetSubjectView(family: .systemMedium)
        case .widgetUnlinked: UnlinkedWidgetSubjectView()
      }
    }

    /**
     The version-history sheet, listing the revisions Dropbox kept of one file.

     The sheet is handed its subject after it is built, exactly as the File
     Provider UI extension's `prepare(forAction:itemIdentifiers:)` hands it one,
     so the load runs as a task rather than in the initializer.
     */
    static func fileVersionsModel() -> FileVersionsModel {
      let model = FileVersionsModel(
        service: SampleFileVersionsService(),
        resolver: SampleFileVersionsTargetResolver(),
        completion: FileVersionsCompletion(complete: {}, cancel: {})
      )
      Task {
        await model.begin(
          inDomain: PreviewHelper.sampleAccounts[0].accountID.providerDomainIdentifier,
          // Opaque on purpose: this is the shape Finder hands a UI extension,
          // and the resolver is what turns it into Dropbox's own identifier.
          itemIdentifiers: [NSFileProviderItemIdentifier("__fp/fs/docID(4266)")]
        )
      }
      return model
    }

    /// The share sheet, with two files staged and both sample accounts to
    /// choose between. The view starts its own load.
    static func shareUploadModel() -> ShareUploadModel {
      ShareUploadModel(
        context: SampleShareRequestContext(),
        service: SampleShareUploadService(),
        // No defaults at all, so the sheet opens on the account root rather
        // than on wherever this Mac last sent a share.
        defaults: nil
      )
    }

    /// What the widget is drawn from: accounts that have been syncing, or the
    /// absent snapshot the widget reads as no account linked.
    static func widgetEntry(linked: Bool) -> SyncStatusEntry {
      SyncStatusEntry(
        date: Date(),
        snapshot: linked ? SyncStatusSnapshot(accounts: widgetAccounts) : nil
      )
    }

    /// The surfaces the gallery can present. The raw value is both what
    /// `--uitest-show-design=` names and the slug the capture is filed under.
    enum Subject: String {
      case fileVersions = "file-versions"
      case shareUpload = "share-upload"
      case widgetSmall = "widget-small"
      case widgetMedium = "widget-medium"
      case widgetUnlinked = "widget-unlinked"
    }
  }

  /**
   The version-history sheet, holding its model for the life of the window.

   `@State` rather than a fresh model per render: a second model would start a
   second load, and the sheet would be photographed mid-flight.
   */
  private struct FileVersionsSubjectView: View {
    @State private var model = DesignGallery.fileVersionsModel()

    var body: some View {
      SheetTile { FileVersionsView(model: model) }
    }
  }

  /**
   The share sheet, holding its model for the life of the window.

   `@State` for a sharper reason than the sheet above: the share flow stages its
   files when the view appears and appends them to what it already has, so a
   model rebuilt on a re-render lists every file twice.
   */
  private struct ShareUploadSubjectView: View {
    @State private var model = DesignGallery.shareUploadModel()

    var body: some View {
      SheetTile { ShareUploadView(model: model) }
    }
  }

  /// The widget's layout for accounts that have been syncing, in the tile
  /// WidgetKit would have drawn around it.
  private struct WidgetSubjectView: View {
    let family: WidgetFamily

    var body: some View {
      WidgetTile(family: family) {
        SyncStatusWidgetBodyView(entry: DesignGallery.widgetEntry(linked: true), family: family)
      }
    }
  }

  /// The widget's layout before any account is linked.
  private struct UnlinkedWidgetSubjectView: View {
    var body: some View {
      WidgetTile(family: .systemSmall) {
        SyncStatusWidgetBodyView(
          entry: DesignGallery.widgetEntry(linked: false),
          family: .systemSmall
        )
      }
    }
  }

  /**
   The shape an extension's sheet is drawn in.

   A sheet is a plain rounded rectangle wearing the system's shadow, and neither
   comes free here: the gallery's window is a plain one, which is the only kind
   whose frame is its content. The radius is the one AppKit rounds a window and
   a sheet alike to.
   */
  private struct SheetTile<Content: View>: View {
    /// The radius AppKit rounds a sheet's corners to.
    private static var cornerRadius: CGFloat { 10 }

    /// How far the shadow beneath a sheet reaches.
    private static var shadowRadius: CGFloat { 14 }

    private let content: Content

    var body: some View {
      content
        // The window is a plain one and draws nothing of its own, so the fill a
        // host's sheet sits on is drawn here — under the header and the footer,
        // which have no background of their own for exactly that reason.
        .background(.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: Self.shadowRadius, y: 5)
        // Room for the shadow to fall in. The window is a plain one, so what it
        // falls on is the staged backdrop.
        .padding(Self.shadowRadius * 2)
    }

    init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }
  }

  /**
   The tile WidgetKit would have drawn around a widget's body.

   WidgetKit sizes the tile, insets the body from its edges, fills it, and clips
   it to a rounded rectangle — none of which it does for a view hosted anywhere
   but a widget extension. The figures below are the platform's, and they are
   the one thing about these two captures that could be wrong without anything
   failing; the real widget on a real desktop is what they are checked against.
   */
  private struct WidgetTile<Content: View>: View {
    /// How far WidgetKit insets a body from the tile's edges.
    private static var contentMargin: CGFloat { 16 }

    /// The tile's corner radius.
    private static var cornerRadius: CGFloat { 24 }

    /// How far the tile's shadow reaches. Every other capture carries the shadow
    /// AppKit draws around a window; this one has no window to take one from,
    /// and a tile without one reads as a rectangle pasted onto the page.
    private static var shadowRadius: CGFloat { 8 }

    private let family: WidgetFamily

    private let content: Content

    var body: some View {
      content
        .padding(Self.contentMargin)
        .frame(width: size.width, height: size.height)
        .background(.fill.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: Self.shadowRadius, y: 3)
        // Room for the shadow to fall in. The window behind it is transparent,
        // so what the shadow falls on is the staged backdrop.
        .padding(Self.shadowRadius * 3)
    }

    /// The size macOS lays this family out at.
    private var size: CGSize {
      switch family {
        case .systemMedium: CGSize(width: 364, height: 170)
        default: CGSize(width: 170, height: 170)
      }
    }

    init(family: WidgetFamily, @ViewBuilder content: () -> Content) {
      self.family = family
      self.content = content()
    }
  }

  /**
   The canned file the version-history sheet is about: its index row, and the
   revisions Dropbox is holding of it.

   Outside ``DesignGallery`` because the services that read it are not
   main-actor isolated, and a resolver called off the main actor cannot reach
   into one that is.
   */
  private enum VersionsSample {
    /// The file's name, as the sheet's breadcrumb and its restored state show it.
    static let fileName = "Quarterly Report.pdf"

    /// Dropbox's identifier for the file, which follows it through renames.
    static var identifier: DropboxFileIdentifier { fileIdentifier("id:a4ayc_80_OEAAAAAAAAAXw") }

    /// Where the file is, as the sheet's breadcrumb reads it.
    static var path: DropboxPath { dropboxPath("/Documents/\(fileName)") }

    /// The revisions Dropbox is holding, newest first.
    private static let storedRevisions = ["a1b2c3d4e5", "9f8e7d6c5b", "4a3b2c1d0e", "0f1e2d3c4b"]

    /// How long ago each revision was recorded. Relative, so a regenerated
    /// capture reads as a file someone has been working on rather than as one
    /// last touched whenever these images happened to be made — the same reason
    /// ``PreviewHelper``'s sync activity is.
    private static let recordedAgo: [TimeInterval] = [
      -3600 * 2, -3600 * 27, -3600 * 24 * 3, -3600 * 24 * 11
    ]

    /// The file's size at each revision, which is what the sheet lists beneath
    /// the times.
    private static let sizes: [UInt64] = [348_112, 347_004, 341_890, 298_455]

    /// The revisions the sheet lists, newest first.
    static var revisions: [(revision: FileRevision, recorded: Date, size: UInt64)] {
      storedRevisions.indices.map {
        (fileRevision(storedRevisions[$0]), Date(timeIntervalSinceNow: recordedAgo[$0]), sizes[$0])
      }
    }

    /// The index's row for the file, which is how the sheet learns its name,
    /// its path, and which revision it is at.
    static var indexEntry: IndexEntryRecord {
      let newest = revisions[0]
      return IndexEntryRecord(
        dbxID: identifier,
        pathNormalized: NormalizedDropboxPath(path),
        parentPathNormalized: NormalizedDropboxPath(path).parent,
        pathCased: path,
        name: fileName,
        itemType: .file,
        revision: newest.revision,
        contentHash: nil,
        symlinkTarget: nil,
        size: newest.size,
        clientModified: newest.recorded,
        serverModified: newest.recorded
      )
    }

    /**
     One revision as `files/list_revisions` returns it.

     JSON because ``FileMetadata`` decodes the wire format and has no memberwise
     initializer — the same reason the unit tests' fixtures are.
     */
    static func metadata(
      revision: FileRevision,
      recorded: Date,
      size: UInt64
    ) throws -> FileMetadata {
      let recordedText = ISO8601DateFormatter().string(from: recorded)
      let json = """
        {
            ".tag": "file",
            "id": "\(identifier.rawValue)",
            "name": "\(fileName)",
            "path_lower": "\(path.rawValue.lowercased())",
            "path_display": "\(path.rawValue)",
            "client_modified": "\(recordedText)",
            "server_modified": "\(recordedText)",
            "rev": "\(revision.rawValue)",
            "size": \(size)
        }
        """
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(FileMetadata.self, from: Data(json.utf8))
    }

    // The literals above are fixed strings from this file, so a validation
    // failure is a typo in the sample data rather than a runtime condition —
    // and one that any capture run trips immediately.
    // swiftlint:disable force_try
    private static func fileIdentifier(_ rawValue: String) -> DropboxFileIdentifier {
      try! DropboxFileIdentifier(validating: rawValue)
    }

    private static func dropboxPath(_ rawValue: String) -> DropboxPath {
      try! DropboxPath(validating: rawValue)
    }

    private static func fileRevision(_ rawValue: String) -> FileRevision {
      try! FileRevision(validating: rawValue)
    }
    // swiftlint:enable force_try
  }

  /// A resolver answering with the one file the gallery is about, since a
  /// canned launch has no File Provider domain to resolve an identifier against.
  private struct SampleFileVersionsTargetResolver: FileVersionsTargetResolving {
    func target(for request: FileVersionsRequest) -> FileVersionsTarget {
      FileVersionsTarget(account: request.account, item: VersionsSample.identifier)
    }
  }

  /// The account layer the version-history sheet reads, answering from
  /// ``VersionsSample`` and restoring nothing.
  private struct SampleFileVersionsService: FileVersionsService {
    func indexedItem(_: DropboxFileIdentifier, in _: AccountIdentifier) -> IndexEntryRecord? {
      VersionsSample.indexEntry
    }

    func revisions(
      of _: DropboxFileIdentifier,
      in _: AccountIdentifier,
      limit _: UInt
    ) throws -> [FileMetadata] {
      try VersionsSample.revisions.map {
        try VersionsSample.metadata(revision: $0.revision, recorded: $0.recorded, size: $0.size)
      }
    }

    func restore(
      _: DropboxPath,
      to revision: FileRevision,
      in _: AccountIdentifier
    ) throws -> FileMetadata {
      try VersionsSample.metadata(
        revision: revision,
        recorded: Date(),
        size: VersionsSample.revisions[0].size
      )
    }
  }

  /// The account layer the share sheet reads, answering from canned accounts
  /// and folders and uploading nothing.
  private struct SampleShareUploadService: ShareUploadService {
    private static let folderPaths = [
      "/Documents", "/Documents/Invoices", "/Pictures", "/Projects", "/Projects/Zephyr"
    ]

    func shareableAccounts() async -> [AccountConfiguration] {
      await PreviewHelper.sampleAccounts
    }

    func knownFolders(for _: AccountIdentifier) throws -> [DropboxPath] {
      try Self.folderPaths.map { try DropboxPath(validating: $0) }
    }

    func newestFolders(for account: AccountIdentifier) throws -> [DropboxPath] {
      try knownFolders(for: account)
    }

    func upload(_: URL, to _: DropboxPath, for _: AccountIdentifier) {}
  }

  /**
   A share request over two files written for the occasion.

   Both are text, and both carry real prose. The sheet draws each row's icon
   from whatever preview it can get, and what it gets is a Quick Look render of
   the staged copy — so a file padded out with nothing renders as a page of
   noise, and every reader of the published image sees it. Real lines render as
   a page of writing, which is what sharing a document looks like.
   */
  @MainActor
  private final class SampleShareRequestContext: ShareRequestContext {
    /// The files being sent, each written out until it is a size a real share
    /// would show rather than the length of a sentence.
    private static let sampleFiles = [
      (name: "Meeting Notes.txt", lines: 120),
      (name: "Reading List.txt", lines: 40)
    ]

    /// The prose the sample files are written out of, repeated until each is
    /// the length it wants to be.
    private static let sampleProse = """
      Agreed the release goes out once the last of the sync issues are closed.
      Tim to write up what changed in the Finder actions and where they live.
      Open question: whether the widget should count folders as well as files.
      Nobody wants another settings pane, so the limits stay where they are.
      """

    /// Where the staged originals are written, one directory per request.
    private let directory = FileManager.default.temporaryDirectory
      .appending(component: "zephyr-gallery-\(UUID().uuidString)")

    private var pending: [NSItemProvider] = []

    /**
     The shared items, handed over once and once only.

     A real share request's attachments are consumed once, and so are these,
     deliberately: giving the gallery's window a title bar to take key with
     rebuilds its contents, which starts the share flow's load a second time —
     and a second load stages the same two files again onto the ones the sheet
     is already listing.
     */
    var sharedAttachments: [NSItemProvider] {
      defer { pending = [] }
      return pending
    }

    init() {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      pending = Self.sampleFiles.compactMap(provider(for:))
    }

    func completeShare() {}

    func cancelShare() {}

    private func provider(for file: (name: String, lines: Int)) -> NSItemProvider? {
      let url = directory.appending(component: file.name)
      let text = Array(repeating: Self.sampleProse, count: file.lines).joined(separator: "\n\n")
      guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
      return NSItemProvider(contentsOf: url)
    }
  }
#endif
