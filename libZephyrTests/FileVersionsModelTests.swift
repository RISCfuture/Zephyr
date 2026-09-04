import FileProvider
import Foundation
import Testing

@testable import libZephyr

@MainActor
@Suite
struct `File version history` {
  private static let domain = versionsDomainIdentifier

  private static func makeModel(
    service: StubFileVersionsService,
    resolver: StubFileVersionsTargetResolver = StubFileVersionsTargetResolver()
  ) -> (FileVersionsModel, RecordingCompletion) {
    let recorder = RecordingCompletion()
    let model = FileVersionsModel(
      service: service,
      resolver: resolver,
      completion: recorder.completion
    )
    return (model, recorder)
  }

  private static func begin(
    _ model: FileVersionsModel,
    domain: String? = Self.domain,
    items: [NSFileProviderItemIdentifier] = [systemItemIdentifier]
  ) async {
    await model.begin(inDomain: domain, itemIdentifiers: items)
  }

  // MARK: - What Finder hands over

  @Test
  func `The domain identifier names the account holding the file`() throws {
    let request = try FileVersionsRequest(
      domainIdentifier: Self.domain,
      itemIdentifiers: [systemItemIdentifier]
    )

    #expect(request.account == (try versionsAccount()))
    #expect(request.identifier == systemItemIdentifier)
  }

  @Test(arguments: [
    [] as [NSFileProviderItemIdentifier],
    [systemItemIdentifier, NSFileProviderItemIdentifier("__fp/fs/docID(4267)")]
  ])
  func `An action on anything but one file is refused`(items: [NSFileProviderItemIdentifier]) {
    #expect(throws: FileVersionsFailure.notOneFile) {
      try FileVersionsRequest(domainIdentifier: Self.domain, itemIdentifiers: items)
    }
  }

  @Test
  func `An action arriving without a recognisable domain is refused`() {
    #expect(throws: FileVersionsFailure.noAccount) {
      try FileVersionsRequest(domainIdentifier: nil, itemIdentifiers: [systemItemIdentifier])
    }
    #expect(throws: FileVersionsFailure.noAccount) {
      try FileVersionsRequest(domainIdentifier: "", itemIdentifiers: [systemItemIdentifier])
    }
  }

  // MARK: - Listing

  @Test
  func `Revisions are listed newest first, with the file's own marked current`() async throws {
    let entry = try fileRecord(
      id: "id:a4ayc_80_OEAAAAAAAAAXw",
      path: "/Homework/Prime_Numbers.txt",
      revision: "a1c10ce0dd78"
    )
    let service = StubFileVersionsService(
      entry: entry,
      revisions: [
        try revisionMetadata(rev: "a1c10ce0dd78", size: 7212),
        try revisionMetadata(rev: "b2d20df1ee89", size: 4096)
      ]
    )
    let (model, _) = Self.makeModel(service: service)

    await Self.begin(model)

    #expect(model.phase == .listing)
    #expect(model.fileName == "Prime_Numbers.txt")
    #expect(model.path?.rawValue == "/Homework/Prime_Numbers.txt")
    #expect(model.revisions.map(\.id.rawValue) == ["a1c10ce0dd78", "b2d20df1ee89"])
    #expect(model.revisions.map(\.isCurrent) == [true, false])
    #expect(model.revisions.first?.size == Measurement(value: 7212, unit: .bytes))
  }

  @Test
  func `The revision the file is already at cannot be restored over itself`() async throws {
    let entry = try fileRecord(
      id: "id:a4ayc_80_OEAAAAAAAAAXw",
      path: "/Homework/Prime_Numbers.txt",
      revision: "a1c10ce0dd78"
    )
    let service = StubFileVersionsService(
      entry: entry,
      revisions: [
        try revisionMetadata(rev: "a1c10ce0dd78"),
        try revisionMetadata(rev: "b2d20df1ee89")
      ]
    )
    let (model, _) = Self.makeModel(service: service)

    await Self.begin(model)

    // The newest revision is the one the file is at, so the sheet opens on the
    // newest one that would actually change something.
    #expect(model.selection?.rawValue == "b2d20df1ee89")
    #expect(model.canRestore)

    model.selection = try FileRevision(validating: "a1c10ce0dd78")
    #expect(!model.canRestore)
  }

  @Test
  func `A file Dropbox kept no earlier version of is an empty sheet, not a failure`() async throws {
    let entry = try fileRecord(id: "id:a4ayc_80_OEAAAAAAAAAXw", path: "/Homework/Notes.txt")
    let (model, _) = Self.makeModel(service: StubFileVersionsService(entry: entry))

    await Self.begin(model)

    #expect(model.phase == .empty)
    #expect(model.revisions.isEmpty)
    #expect(!model.canRestore)
  }

  // MARK: - Restoring

  @Test
  func `Restoring puts the chosen revision back at the file's own path`() async throws {
    let entry = try fileRecord(
      id: "id:a4ayc_80_OEAAAAAAAAAXw",
      path: "/Homework/Prime_Numbers.txt",
      revision: "a1c10ce0dd78"
    )
    let service = StubFileVersionsService(
      entry: entry,
      revisions: [
        try revisionMetadata(rev: "a1c10ce0dd78"),
        try revisionMetadata(rev: "b2d20df1ee89")
      ]
    )
    let (model, recorder) = Self.makeModel(service: service)
    await Self.begin(model)

    await model.restore()

    #expect(model.phase == .restored)
    #expect(
      service.restores == [
        .init(
          path: try DropboxPath(validating: "/Homework/Prime_Numbers.txt"),
          revision: try FileRevision(validating: "b2d20df1ee89"),
          account: try versionsAccount()
        )
      ]
    )
    // The sheet stays open on the result; the reader dismisses it.
    #expect(recorder.completionCount == 0)
    model.finish()
    #expect(recorder.completionCount == 1)
  }

  // MARK: - Failures

  @Test
  func `A file that cannot be resolved says so rather than showing an empty list`() async {
    let resolver = StubFileVersionsTargetResolver(failure: FileVersionsFailure.fileUnavailable)
    let (model, _) = Self.makeModel(service: StubFileVersionsService(), resolver: resolver)

    await Self.begin(model)

    #expect(
      model.phase
        == .failed(
          ErrorSentence.describe(FileVersionsFailure.fileUnavailable, includingRecovery: true)
        )
    )
  }

  @Test
  func `A refusal from Dropbox is reported in the reader's words, recovery included`() async throws
  {
    let entry = try fileRecord(id: "id:a4ayc_80_OEAAAAAAAAAXw", path: "/Homework/Notes.txt")
    let failure = ItemSyncFailure.insufficientPermissions(path: "/Homework/Notes.txt", detail: nil)
    let (model, _) = Self.makeModel(
      service: StubFileVersionsService(entry: entry, revisionsFailure: failure)
    )

    await Self.begin(model)

    #expect(model.phase == .failed(ErrorSentence.describe(failure, includingRecovery: true)))
  }

  @Test
  func `The authentication error the system reports is shown in the sheet`() {
    let (model, _) = Self.makeModel(service: StubFileVersionsService())

    model.show(AuthenticationFailure.tokenRevoked)

    #expect(
      model.phase
        == .failed(
          ErrorSentence.describe(AuthenticationFailure.tokenRevoked, includingRecovery: true)
        )
    )
  }
}
