import Foundation
import Security
import Testing

@testable import libZephyr

/**
 End-to-end tests against the real Dropbox API, enabled only when a refresh
 token is supplied:

     TEST_RUNNER_DROPBOX_REFRESH_TOKEN=… xcodebuild test -scheme libZephyr

 The `TEST_RUNNER_` prefix is what carries the value across into the test
 process, which sees it under the unprefixed name below; xcodebuild does not
 forward its own environment. Setting `DROPBOX_REFRESH_TOKEN` directly leaves
 the suite silently skipped.

 All remote activity happens under a uniquely-named folder that is deleted
 when the test finishes, pass or fail.
 */
@Suite(.serialized, .enabled(if: LinkedDropbox.refreshToken != nil))
struct LinkedEndToEndTests {
  @Test
  func `remote file lifecycle`() async throws {
    try await LinkedDropbox.withTestFolder { client, folder in
      let scratch = try LinkedDropbox.makeScratchDirectory()
      defer { try? FileManager.default.removeItem(at: scratch) }

      // A payload big enough to exercise the 4 MiB upload-session path.
      let payload = LinkedDropbox.randomPayload(mebibytes: 9)
      let originalURL = scratch.appendingPathComponent("large.bin")
      try payload.write(to: originalURL)
      let largePath = try folder.appending("large.bin")
      let uploaded = try await FileUploader(client: client)
        .upload(originalURL, to: largePath, mode: .add)
      #expect(uploaded.size == UInt64(payload.count))
      #expect(uploaded.contentHash == (try DropboxContentHasher.hash(contentsOf: originalURL)))

      let roundtripURL = scratch.appendingPathComponent("roundtrip.bin")
      _ = try await FileDownloader(client: client).download(.path(largePath), to: roundtripURL)
      #expect(try Data(contentsOf: roundtripURL) == payload)

      // Revisions and restore on a small, single-shot file.
      let notePath = try folder.appending("note.txt")
      let noteURL = scratch.appendingPathComponent("note.txt")
      try Data("version one\n".utf8).write(to: noteURL)
      let first = try await FileUploader(client: client)
        .upload(noteURL, to: notePath, mode: .add)
      try Data("version two\n".utf8).write(to: noteURL)
      let second = try await FileUploader(client: client)
        .upload(noteURL, to: notePath, mode: .overwrite)

      let revisions = try await client.revisions(of: .path(notePath))
      #expect(revisions.count >= 2)
      #expect(revisions.first?.rev == second.rev)

      _ = try await client.restore(notePath, to: first.rev)
      let restoredURL = scratch.appendingPathComponent("restored.txt")
      _ = try await FileDownloader(client: client).download(.path(notePath), to: restoredURL)
      #expect(
        String(bytes: try Data(contentsOf: restoredURL), encoding: .utf8) == "version one\n"
      )

      // Shared links.
      let link = try await client.createSharedLink(for: notePath)
      let listed = try await client.listSharedLinks(for: notePath)
      #expect(listed.links.contains { $0.url == link.url })
      try await client.revokeSharedLink(link.url)

      // Server-side move, then a revision-guarded delete.
      let renamedPath = try folder.appending("note-renamed.txt")
      _ = try await client.move(from: .path(notePath), to: renamedPath)
      #expect(try await client.metadata(for: .path(notePath)) == nil)
      #expect(try await client.metadata(for: .path(renamedPath)) != nil)

      _ = try await client.delete(.path(largePath), parentRevision: uploaded.rev)
      #expect(try await client.metadata(for: .path(largePath)) == nil)
    }
  }

  @Test
  func `delta feed delivers remote changes`() async throws {
    try await LinkedDropbox.withTestFolder { client, folder in
      let cursor = try await client.latestCursor(for: folder)

      let scratch = try LinkedDropbox.makeScratchDirectory()
      defer { try? FileManager.default.removeItem(at: scratch) }
      let localURL = scratch.appendingPathComponent("delta.txt")
      try Data("delta payload\n".utf8).write(to: localURL)
      _ = try await FileUploader(client: client)
        .upload(localURL, to: try folder.appending("delta.txt"), mode: .add)

      // Changes already exist, so the longpoll returns immediately.
      let longpoll = try await client.waitForChanges(after: cursor)
      #expect(longpoll.changes)

      var entries: [ItemMetadata] = []
      var page = try await client.listFolderContinue(from: cursor)
      entries.append(contentsOf: page.entries)
      while page.hasMore {
        page = try await client.listFolderContinue(from: page.cursor)
        entries.append(contentsOf: page.entries)
      }
      #expect(entries.contains { $0.name == "delta.txt" })
    }
  }
}

/// Client plumbing and remote-folder scaffolding for the linked suite.
enum LinkedDropbox {
  static let refreshToken = ProcessInfo.processInfo.environment["DROPBOX_REFRESH_TOKEN"]

  /// Builds a path-rooted client for the token's account.
  static func makeClient() async throws -> DropboxClient {
    let token = try #require(refreshToken)
    let base = DropboxClient(tokenProvider: AccessTokenProvider(refreshToken: token))
    let account = try await base.currentAccount()
    return base.withPathRoot(PathRoot(namespaceID: account.rootInfo.rootNamespaceID))
  }

  /// Runs the body with a fresh uniquely-named remote folder, deleting it afterward.
  static func withTestFolder(
    _ body: (DropboxClient, DropboxPath) async throws -> Void
  ) async throws {
    let client = try await makeClient()
    let folder = try DropboxPath(validating: "/Zephyr-e2e-\(UUID().uuidString.prefix(8))")
    _ = try await client.createFolder(at: folder)
    do {
      try await body(client, folder)
    } catch {
      _ = try? await client.delete(.path(folder))
      throw error
    }
    _ = try await client.delete(.path(folder))
  }

  static func makeScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("zephyr-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Random-prefixed repeating payload of the given size.
  static func randomPayload(mebibytes: Int) -> Data {
    var block = Data(count: 1 << 20)
    block.withUnsafeMutableBytes { buffer in
      _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    var payload = Data(capacity: mebibytes << 20)
    for _ in 0..<mebibytes {
      payload.append(block)
    }
    return payload
  }
}

extension DropboxPath {
  fileprivate func appending(_ name: String) throws -> DropboxPath {
    try DropboxPath(validating: rawValue + "/" + name)
  }
}
