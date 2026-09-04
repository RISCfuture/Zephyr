import Foundation
import Testing

@testable import libZephyr

@MainActor
@Suite
struct `Share upload flow` {
  private static func makeModel(
    sharing urls: [URL],
    service: StubShareUploadService,
    defaults: UserDefaults? = nil
  ) -> (ShareUploadModel, RecordingShareRequestContext) {
    let context = RecordingShareRequestContext(sharing: urls)
    let model = ShareUploadModel(context: context, service: service, defaults: defaults)
    return (model, context)
  }

  @Test
  func `Loading stages every shared file and offers the linked accounts`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt", "Budget.csv"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let personal = try shareAccount("Personal")
    let (model, _) = Self.makeModel(
      sharing: urls,
      service: StubShareUploadService(accounts: [personal])
    )

    await model.load()

    #expect(model.phase == .ready)
    #expect(model.files.map(\.lastPathComponent) == ["Notes.txt", "Budget.csv"])
    #expect(model.skippedNames.isEmpty)
    #expect(model.accounts == [personal])
    #expect(model.selectedAccountID == personal.accountID)
    #expect(model.canUpload)
    // Staged out from under the sharing app, so the upload survives its exit.
    for file in model.files {
      #expect(file.path.contains("zephyr-share-"))
      #expect(FileManager.default.fileExists(atPath: file.path))
    }
  }

  @Test
  func `A shared folder is skipped by name rather than failing the whole share`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let nested = directory.appendingPathComponent("Trip Photos")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let (model, _) = Self.makeModel(
      sharing: urls + [nested],
      service: StubShareUploadService(accounts: [try shareAccount("Personal")])
    )

    await model.load()

    #expect(model.phase == .ready)
    #expect(model.files.map(\.lastPathComponent) == ["Notes.txt"])
    #expect(model.skippedNames == ["Trip Photos"])
  }

  @Test
  func `An account layer that can't answer stops the flow with its reason`() async throws {
    let (model, _) = Self.makeModel(
      sharing: [],
      service: StubShareUploadService(accountsFailure: EngineFailure.notLinked)
    )

    await model.load()

    #expect(model.canUpload == false)
    guard case let .failed(message) = model.phase else {
      Issue.record("Expected a failed phase, got \(model.phase)")
      return
    }
    #expect(message.isEmpty == false)
  }

  @Test
  func `Uploading sends every file into the chosen folder and dismisses the sheet`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt", "Budget.csv"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let personal = try shareAccount("Personal")
    let service = StubShareUploadService(
      accounts: [personal],
      indexed: try folders("/Camera Uploads")
    )
    let (model, context) = Self.makeModel(sharing: urls, service: service)

    await model.load()
    model.choose(try DropboxPath(validating: "/Camera Uploads"))
    await model.upload()

    #expect(model.phase == .finished)
    #expect(context.completionCount == 1)
    #expect(context.cancellationCount == 0)
    #expect(service.requests.map(\.fileName) == ["Notes.txt", "Budget.csv"])
    #expect(
      service.requests.map(\.path.displayPath) == [
        "/Camera Uploads/Notes.txt", "/Camera Uploads/Budget.csv"
      ]
    )
    #expect(service.requests.allSatisfy { $0.account == personal.accountID })
    // The staging directory goes with the sheet.
    #expect(model.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
  }

  @Test
  func `A share with no folder chosen goes to the account root`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = StubShareUploadService(accounts: [try shareAccount("Personal")])
    let (model, _) = Self.makeModel(sharing: urls, service: service)

    #expect(model.destination == .root)
    await model.load()
    await model.upload()

    #expect(service.requests.map(\.path.displayPath) == ["/Notes.txt"])
  }

  @Test
  func `A failed upload leaves the sheet open with the reason, not silently dismissed`()
    async throws
  {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = StubShareUploadService(
      accounts: [try shareAccount("Personal")],
      uploadFailure: EngineFailure.notLinked
    )
    let (model, context) = Self.makeModel(sharing: urls, service: service)

    await model.load()
    await model.upload()

    guard case .failed = model.phase else {
      Issue.record("Expected a failed phase, got \(model.phase)")
      return
    }
    #expect(context.completionCount == 0)
  }

  @Test
  func `Cancelling abandons the request and clears the staged copies`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, context) = Self.makeModel(
      sharing: urls,
      service: StubShareUploadService(accounts: [try shareAccount("Personal")])
    )

    await model.load()
    let staged = model.files
    model.cancel()

    #expect(context.cancellationCount == 1)
    #expect(context.completionCount == 0)
    #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    // The originals belong to whoever shared them.
    #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }

  @Test
  func `Nothing can be uploaded before an account and a file are both in hand`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }

    let (unlinked, _) = Self.makeModel(sharing: urls, service: StubShareUploadService())
    await unlinked.load()
    #expect(unlinked.canUpload == false)

    let (empty, _) = Self.makeModel(
      sharing: [],
      service: StubShareUploadService(accounts: [try shareAccount("Personal")])
    )
    await empty.load()
    #expect(empty.canUpload == false)
  }
}

@MainActor
@Suite
struct `Share destination` {
  private func makeModel(
    service: StubShareUploadService,
    defaults: UserDefaults? = nil
  ) -> ShareUploadModel {
    ShareUploadModel(
      context: RecordingShareRequestContext(),
      service: service,
      defaults: defaults
    )
  }

  @Test
  func `A folder made elsewhere shows up without waiting for the index`() async throws {
    let service = StubShareUploadService(
      accounts: [try shareAccount("Personal")],
      indexed: try folders("/Camera Uploads", "/Receipts"),
      fromDropbox: try folders("/Camera Uploads", "/Brand New")
    )
    let model = makeModel(service: service)

    await model.load()
    await model.settleFolders()

    // The new one joins the indexed ones; the one both knew is not doubled.
    #expect(model.folders.map(\.displayPath) == ["/Brand New", "/Camera Uploads", "/Receipts"])
  }

  @Test
  func `A refresh that can't reach Dropbox leaves the indexed folders standing`() async throws {
    let service = StubShareUploadService(
      accounts: [try shareAccount("Personal")],
      indexed: try folders("/Camera Uploads", "/Receipts"),
      refreshFails: true
    )
    let model = makeModel(service: service)

    await model.load()
    await model.settleFolders()

    #expect(model.folders.map(\.displayPath) == ["/Camera Uploads", "/Receipts"])
  }

  @Test
  func `The browser filters on any part of a folder's path, ignoring case`() async throws {
    let service = StubShareUploadService(
      accounts: [try shareAccount("Personal")],
      indexed: try folders("/Camera Uploads", "/Receipts", "/Receipts/2026", "/Scans")
    )
    let model = makeModel(service: service)
    await model.load()
    await model.settleFolders()

    model.browseFolders()
    #expect(model.isBrowsingFolders)
    #expect(model.matchingFolders.count == 4)

    model.folderSearch = "rec"
    #expect(model.matchingFolders.map(\.displayPath) == ["/Receipts", "/Receipts/2026"])

    model.folderSearch = "2026"
    #expect(model.matchingFolders.map(\.displayPath) == ["/Receipts/2026"])
  }

  @Test
  func `Choosing a folder sets the destination and closes the browser`() async throws {
    let model = makeModel(
      service: StubShareUploadService(
        accounts: [try shareAccount("Personal")],
        indexed: try folders("/Receipts")
      )
    )
    await model.load()
    model.browseFolders()
    model.choose(try DropboxPath(validating: "/Receipts"))

    #expect(model.isBrowsingFolders == false)
    #expect(model.destination.displayPath == "/Receipts")
  }

  @Test
  func `Backing out of the browser keeps the destination it opened on`() async throws {
    let model = makeModel(
      service: StubShareUploadService(accounts: [try shareAccount("Personal")])
    )
    await model.load()
    model.choose(try DropboxPath(validating: "/Receipts"))
    model.browseFolders()
    model.cancelBrowsingFolders()

    #expect(model.isBrowsingFolders == false)
    #expect(model.destination.displayPath == "/Receipts")
  }

  @Test
  func `The folders a share went to are what the next share offers, newest first`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let personal = try shareAccount("Personal")

    try await withTemporaryDefaults { defaults in
      for folder in ["/Receipts", "/Camera Uploads", "/Receipts"] {
        let model = ShareUploadModel(
          context: RecordingShareRequestContext(sharing: urls),
          service: StubShareUploadService(accounts: [personal]),
          defaults: defaults
        )
        await model.load()
        model.choose(try DropboxPath(validating: folder))
        await model.upload()
      }

      let next = ShareUploadModel(
        context: RecordingShareRequestContext(),
        service: StubShareUploadService(accounts: [personal]),
        defaults: defaults
      )
      await next.load()
      // Newest first, and a folder used twice is listed once.
      #expect(next.recentFolders.map(\.displayPath) == ["/Receipts", "/Camera Uploads"])
      #expect(next.destination.displayPath == "/Receipts")
    }
  }

  @Test
  func `Only the newest few folders are remembered`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let personal = try shareAccount("Personal")

    try await withTemporaryDefaults { defaults in
      let newest = ShareUploadModel.maximumRecentFolders + 3
      for index in 1...newest {
        let model = ShareUploadModel(
          context: RecordingShareRequestContext(sharing: urls),
          service: StubShareUploadService(accounts: [personal]),
          defaults: defaults
        )
        await model.load()
        model.choose(try DropboxPath(validating: "/Folder \(index)"))
        await model.upload()
      }

      let next = ShareUploadModel(
        context: RecordingShareRequestContext(),
        service: StubShareUploadService(accounts: [personal]),
        defaults: defaults
      )
      await next.load()
      #expect(next.recentFolders.count == ShareUploadModel.maximumRecentFolders)
      #expect(next.recentFolders.first?.displayPath == "/Folder \(newest)")
    }
  }

  @Test
  func `A remembered folder that no longer parses is dropped rather than offered`() async throws {
    try await withTemporaryDefaults { defaults in
      let personal = try shareAccount("Personal")
      defaults.set(
        ["/Receipts", "//broken", "no-leading-slash"],
        forKey: rememberedFoldersKey(for: personal)
      )
      let model = makeModel(
        service: StubShareUploadService(accounts: [personal]),
        defaults: defaults
      )
      await model.load()
      #expect(model.recentFolders.map(\.displayPath) == ["/Receipts"])
      #expect(model.destination.displayPath == "/Receipts")
    }
  }

  @Test
  func `The destination menu always offers the account root and the current folder`() async throws {
    let model = makeModel(
      service: StubShareUploadService(accounts: [try shareAccount("Personal")])
    )
    await model.load()
    model.choose(try DropboxPath(validating: "/Scans"))

    let offered = model.offeredFolders.map(\.displayPath)
    #expect(offered.first == "/Scans")
    #expect(offered.contains("/"))
  }

  @Test
  func `Switching accounts leaves the other Dropbox's folder behind`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Invoice.pdf"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let personal = try shareAccount("Personal")
    let work = try shareAccount("Work", id: "dbid:AAH4f99T0taONIb-work")

    await withTemporaryDefaults { defaults in
      defaults.set(["/Work/Invoices"], forKey: rememberedFoldersKey(for: work))
      let service = StubShareUploadService(accounts: [work, personal])
      let context = RecordingShareRequestContext(sharing: urls)
      let model = ShareUploadModel(context: context, service: service, defaults: defaults)
      await model.load()
      #expect(model.destination.displayPath == "/Work/Invoices")

      model.selectedAccountID = personal.accountID
      await model.settleFolders()

      // `files/upload` creates the parents of a path it is given, so carrying
      // "/Work/Invoices" across would not merely miss — it would build a
      // "/Work/Invoices" in a Dropbox that never had one.
      #expect(model.destination == .root)
      #expect(model.recentFolders.isEmpty)
      #expect(!model.offeredFolders.contains { $0.displayPath == "/Work/Invoices" })

      await model.upload()
      #expect(service.requests.map(\.path.displayPath) == ["/Invoice.pdf"])
      #expect(service.requests.map(\.account) == [personal.accountID])
    }
  }

  @Test
  func `Each account remembers the folders its own shares went to`() async throws {
    let (directory, urls) = try makeSharedFiles(named: ["Notes.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let personal = try shareAccount("Personal")
    let work = try shareAccount("Work", id: "dbid:AAH4f99T0taONIb-work")

    try await withTemporaryDefaults { defaults in
      let model = ShareUploadModel(
        context: RecordingShareRequestContext(sharing: urls),
        service: StubShareUploadService(accounts: [work, personal]),
        defaults: defaults
      )
      await model.load()
      model.choose(try DropboxPath(validating: "/Work/Invoices"))
      await model.upload()

      let next = ShareUploadModel(
        context: RecordingShareRequestContext(),
        service: StubShareUploadService(accounts: [work, personal]),
        defaults: defaults
      )
      await next.load()
      #expect(next.destination.displayPath == "/Work/Invoices")

      next.selectedAccountID = personal.accountID
      await next.settleFolders()
      #expect(next.destination == .root)

      // And going back finds the work account's folder where it was left.
      next.selectedAccountID = work.accountID
      await next.settleFolders()
      #expect(next.destination.displayPath == "/Work/Invoices")
    }
  }
}
