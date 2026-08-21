import Foundation

/**
 Downloads Dropbox files with content-hash verification and atomic placement:
 the content lands in a hidden temporary file beside the destination (same
 volume, so the final move is atomic), is verified against the server's
 content hash, gets its modification time set, and only then replaces the
 destination — Maestral's download semantics.
 */
struct FileDownloader: Sendable {
  /// The budget and the wait a re-download gets, shared with every other
  /// caller that retries corrupted bytes.
  private static let policy = RetryPolicy()

  private let client: DropboxClient

  init(client: DropboxClient) {
    self.client = client
  }

  /**
   Downloads the content named by `specifier` to `destination`, overwriting
   any existing file once the content verifies.

   Pin a revision with ``PathSpecifier/revision(_:)`` so a concurrent remote
   update cannot tear the download.
   */
  func download(_ specifier: PathSpecifier, to destination: URL) async throws -> FileMetadata {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      throw ItemSyncFailure.isAFolder(path: destination.path)
    }
    let temporaryURL =
      destination
      .deletingLastPathComponent()
      .appendingPathComponent(".zephyr-download-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    var attempt: UInt = 0
    var generator = SystemRandomNumberGenerator()
    while true {
      let metadata = try await client.downloadContent(of: specifier, to: temporaryURL)
      if let expected = metadata.contentHash {
        let actual = try DropboxContentHasher.hash(contentsOf: temporaryURL)
        guard actual == expected else {
          try await waitBeforeRedownloading(
            specifier,
            attempt: &attempt,
            generator: &generator
          )
          continue
        }
      }
      try place(temporaryURL, at: destination, for: metadata)
      return metadata
    }
  }

  /// Waits out the policy's delay before fetching the content again, or
  /// reports the corruption once the policy's budget is spent.
  private func waitBeforeRedownloading(
    _ specifier: PathSpecifier,
    attempt: inout UInt,
    generator: inout SystemRandomNumberGenerator
  ) async throws {
    switch Self.policy.decision(for: .dataCorruption, attempt: attempt, using: &generator) {
      case .retry(let delay):
        try await ContinuousClock().sleep(for: delay)
        attempt += 1
      case .giveUp:
        throw ItemSyncFailure.dataCorruption(path: specifier.wireValue)
    }
  }

  private func place(_ temporaryURL: URL, at destination: URL, for metadata: FileMetadata) throws {
    let modificationDate = min(metadata.clientModified, metadata.serverModified, Date())
    try FileManager.default.setAttributes(
      [.modificationDate: modificationDate],
      ofItemAtPath: temporaryURL.path
    )
    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
  }
}
