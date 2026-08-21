import SwiftUI

/**
 The version-history sheet: a band naming Zephyr, the file being looked at, the
 revisions Dropbox kept of it, and the actions.

 Only the middle band changes with the phase, so the buttons stay where the
 reader last saw them.
 */
public struct FileVersionsView: View {
  /**
   The size the sheet opens at, and keeps.

   Finder reads a size once and holds the extension to it, so this covers the
   tallest thing the sheet shows — a full list of revisions — and every shorter
   state centres itself in the same frame.
   */
  public static let sheetSize = CGSize(width: 460, height: 340)

  @Bindable var model: FileVersionsModel

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
  }

  /// Shows the version history `model` is reading.
  public init(model: FileVersionsModel) {
    self.model = model
  }
}

/// Whatever the sheet's current phase calls for.
private struct PhaseContentView: View {
  @Bindable var model: FileVersionsModel

  var body: some View {
    switch model.phase {
      case .loading:
        ProgressView { Text("Reading earlier versions…", bundle: #bundle) }
          .controlSize(.small)
      case .listing, .restoring:
        RevisionList(model: model)
      case .empty:
        AdvisoryView(
          LocalizedStringResource(
            "Dropbox has kept no earlier version of this file.",
            bundle: #bundle
          ),
          symbol: "clock.badge.questionmark"
        )
      case .restored:
        RestoredView(fileName: model.fileName)
      case let .failed(message):
        Text(message)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
    }
  }
}

/// The file, and the revisions Dropbox is holding of it.
private struct RevisionList: View {
  @Bindable var model: FileVersionsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let path = model.path {
        PathBreadcrumb(path)
          .padding(.horizontal, Metrics.sheetGutter)
          .padding(.vertical, 8)
        Divider()
      }
      List(model.revisions, selection: $model.selection) { revision in
        RevisionRow(revision: revision)
      }
      .listStyle(.inset)
      .accessibilityIdentifier("versionsList")
    }
    .disabled(model.phase == .restoring)
  }
}

/// One stored revision: when Dropbox recorded it, and how big the file was.
private struct RevisionRow: View {
  let revision: FileVersionsModel.Revision

  var body: some View {
    HStack(spacing: Metrics.beforeTrailingSymbol) {
      VStack(alignment: .leading, spacing: Metrics.tight) {
        Text(revision.recorded, format: .dateTime.day().month().year().hour().minute())
        Text(revision.size.formatted(.byteCount(style: .file)))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if revision.isCurrent {
        Text("Current", bundle: #bundle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

/// What the sheet says once the file has been put back.
private struct RestoredView: View {
  let fileName: String

  var body: some View {
    VStack(spacing: 7) {
      Label {
        Text("Restored “\(fileName)”.", bundle: #bundle)
      } icon: {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(ZephyrPalette.active)
      }
      // Restoring writes to Dropbox, and this Mac hears about it the same way
      // it hears about a change made anywhere else: when the change feed comes
      // round. Saying so is better than a Finder window that looks unchanged.
      Text("Finder will catch up in a moment.", bundle: #bundle)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 30)
    .multilineTextAlignment(.center)
  }
}

/// The band holding the actions.
private struct SheetFooter: View {
  @Bindable var model: FileVersionsModel

  var body: some View {
    HStack(spacing: 8) {
      Spacer()
      switch model.phase {
        case .listing, .restoring:
          Button(LocalizedStringResource("Cancel", bundle: #bundle)) { model.cancel() }
            .keyboardShortcut(.cancelAction)
            .disabled(model.phase == .restoring)
          Button(LocalizedStringResource("Restore…", bundle: #bundle)) {
            model.isConfirmingRestore = true
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canRestore)
          .accessibilityIdentifier("restoreRevisionButton")
        case .restored:
          Button(LocalizedStringResource("Done", bundle: #bundle)) { model.finish() }
            .keyboardShortcut(.defaultAction)
        default:
          Button(LocalizedStringResource("Close", bundle: #bundle)) { model.cancel() }
            .keyboardShortcut(.cancelAction)
      }
    }
    .padding(.horizontal, Metrics.sheetGutter)
    .padding(.vertical, 11)
    .confirmationDialog(
      Text("Restore “\(model.fileName)” to this version?", bundle: #bundle),
      isPresented: $model.isConfirmingRestore,
      titleVisibility: .visible
    ) {
      Button(LocalizedStringResource("Restore", bundle: #bundle)) {
        Task { await model.restore() }
      }
    } message: {
      // The one action here the reader cannot undo by repeating it, which is
      // why it asks -- the same reason `RestoreRevisionIntent` asks.
      Text("What the file says now will be replaced.", bundle: #bundle)
    }
  }
}

#if DEBUG
  import FileProvider

  /// Builds the sheet's models on canned revisions, one per phase the previews
  /// below show.
  @MainActor
  private enum PreviewHelper {
    /// The sheet as it opens, before Finder has said which file it is about.
    static let loading = model(reading: SampleFileVersionsService(), begun: false)

    /// The sheet listing what Dropbox kept, the file at the newest revision.
    static let listing = model(reading: SampleFileVersionsService())

    /// The sheet on a file Dropbox has kept no earlier version of.
    static let nothingKept = model(reading: SampleFileVersionsService(listsRevisions: false))

    /// The sheet on a file that is no longer there to read.
    static let failed = model(reading: UnavailableFileVersionsService())

    /**
     A model on `service`, handed its file the way Finder hands a UI extension
     one: after the view exists, so the load runs as a task rather than in the
     initializer.
     */
    private static func model(
      reading service: any FileVersionsService,
      begun: Bool = true
    ) -> FileVersionsModel {
      let model = FileVersionsModel(
        service: service,
        resolver: SampleFileVersionsTargetResolver(),
        completion: FileVersionsCompletion(complete: {}, cancel: {})
      )
      guard begun else { return model }
      Task {
        await model.begin(
          inDomain: VersionsSample.account.providerDomainIdentifier,
          // Opaque on purpose: this is the shape Finder hands a UI extension,
          // and the resolver is what turns it into Dropbox's own identifier.
          itemIdentifiers: [NSFileProviderItemIdentifier("__fp/fs/docID(4266)")]
        )
      }
      return model
    }
  }

  /**
   The canned file the previews are about: its index row, and the revisions
   Dropbox is holding of it.

   Outside ``PreviewHelper`` because the services that read it are not
   main-actor isolated, and one called off the main actor cannot reach into one
   that is.
   */
  private enum VersionsSample {
    /// The file's name, as the sheet's breadcrumb and its restored state show it.
    static let fileName = "Quarterly Report.pdf"

    /// The account the previewed action arrived from.
    static var account: AccountIdentifier { accountIdentifier("dbid:preview-personal") }

    /// Dropbox's identifier for the file, which follows it through renames.
    static var identifier: DropboxFileIdentifier { fileIdentifier("id:a4ayc_80_OEAAAAAAAAAXw") }

    /// Where the file is, as the sheet's breadcrumb reads it.
    static var path: DropboxPath { dropboxPath("/Clients/Northwind, LLC/\(fileName)") }

    /// The revisions Dropbox is holding, newest first: its name for each, how
    /// long ago it was recorded, and how big the file was. Relative, so the
    /// list reads as a file someone has been working on.
    static var stored: [(revision: String, recordedAgo: TimeInterval, size: UInt64)] {
      [
        ("a1b2c3d4e5", -3600 * 2, 348_112),
        ("9f8e7d6c5b", -3600 * 27, 347_004),
        ("4a3b2c1d0e", -3600 * 24 * 3, 341_890),
        ("0f1e2d3c4b", -3600 * 24 * 11, 298_455)
      ]
    }

    /// The index's row for the file, which is how the sheet learns its name,
    /// its path, and which revision it is at.
    static var indexEntry: IndexEntryRecord {
      let newest = stored[0]
      let recorded = Date(timeIntervalSinceNow: newest.recordedAgo)
      return IndexEntryRecord(
        dbxID: identifier,
        pathNormalized: NormalizedDropboxPath(path),
        parentPathNormalized: NormalizedDropboxPath(path).parent,
        pathCased: path,
        name: fileName,
        itemType: .file,
        revision: fileRevision(newest.revision),
        contentHash: nil,
        symlinkTarget: nil,
        size: newest.size,
        clientModified: recorded,
        serverModified: recorded
      )
    }

    /**
     The revisions as `files/list_revisions` returns them.

     JSON because ``FileMetadata`` decodes the wire format and has no memberwise
     initializer — the same reason the unit tests' fixtures are.
     */
    static func metadata() throws -> [FileMetadata] {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try stored.map { revision in
        let recorded = ISO8601DateFormatter()
          .string(from: Date(timeIntervalSinceNow: revision.recordedAgo))
        let json = """
          {
              ".tag": "file",
              "id": "\(identifier.rawValue)",
              "name": "\(fileName)",
              "path_lower": "\(path.rawValue.lowercased())",
              "path_display": "\(path.rawValue)",
              "client_modified": "\(recorded)",
              "server_modified": "\(recorded)",
              "rev": "\(revision.revision)",
              "size": \(revision.size)
          }
          """
        return try decoder.decode(FileMetadata.self, from: Data(json.utf8))
      }
    }

    // The literals above are fixed strings from this file, so a validation
    // failure is a typo in the sample data.
    // swiftlint:disable force_try
    private static func accountIdentifier(_ rawValue: String) -> AccountIdentifier {
      try! AccountIdentifier(validating: rawValue)
    }

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

  /// A resolver answering with the one file the previews are about, since a
  /// preview has no File Provider domain to resolve an identifier against.
  private struct SampleFileVersionsTargetResolver: FileVersionsTargetResolving {
    func target(for request: FileVersionsRequest) -> FileVersionsTarget {
      FileVersionsTarget(account: request.account, item: VersionsSample.identifier)
    }
  }

  /// The account layer the sheet reads, answering from ``VersionsSample``.
  private struct SampleFileVersionsService: FileVersionsService {
    /// Whether Dropbox kept anything earlier, which is the difference between
    /// the list and the advisory that stands in for it.
    var listsRevisions = true

    func indexedItem(_: DropboxFileIdentifier, in _: AccountIdentifier) -> IndexEntryRecord? {
      VersionsSample.indexEntry
    }

    func revisions(
      of _: DropboxFileIdentifier,
      in _: AccountIdentifier,
      limit _: UInt
    ) throws -> [FileMetadata] {
      try listsRevisions ? VersionsSample.metadata() : []
    }

    func restore(
      _: DropboxPath,
      to _: FileRevision,
      in _: AccountIdentifier
    ) throws -> FileMetadata {
      try VersionsSample.metadata()[0]
    }
  }

  /// The account layer refusing the file, as it does for one moved or deleted
  /// since the menu was opened.
  private struct UnavailableFileVersionsService: FileVersionsService {
    func indexedItem(
      _: DropboxFileIdentifier,
      in _: AccountIdentifier
    ) throws -> IndexEntryRecord? {
      throw FileVersionsFailure.fileUnavailable
    }

    func revisions(
      of _: DropboxFileIdentifier,
      in _: AccountIdentifier,
      limit _: UInt
    ) throws -> [FileMetadata] {
      throw FileVersionsFailure.fileUnavailable
    }

    func restore(
      _: DropboxPath,
      to _: FileRevision,
      in _: AccountIdentifier
    ) throws -> FileMetadata {
      throw FileVersionsFailure.fileUnavailable
    }
  }

  #Preview("Opening") {
    FileVersionsView(model: PreviewHelper.loading)
  }

  #Preview("Revisions Dropbox kept") {
    FileVersionsView(model: PreviewHelper.listing)
  }

  #Preview("Nothing kept") {
    FileVersionsView(model: PreviewHelper.nothingKept)
  }

  #Preview("File no longer there") {
    FileVersionsView(model: PreviewHelper.failed)
  }
#endif
