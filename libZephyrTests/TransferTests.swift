import Foundation
import Testing
@testable import libZephyr

@Suite
struct TransferTests {
  private static let chunkSize = 4 * 1024 * 1024
  private static let smallFileSize = 1024
  private static let largeFileSize = 9 * 1024 * 1024
  private static let revision = "0123456789abcdef0"
  private static let clientModifiedISO = "2026-01-02T03:04:05Z"
  private static let serverModifiedISO = "2026-01-01T00:00:00Z"
  private static let serverModified = Date(timeIntervalSince1970: 1_767_225_600)
  private static let largeFileData = patternedData(count: largeFileSize)

  /// A chunk's worth of bytes the large fixture does not begin with.
  private static let someOtherFileData = Data(repeating: 0xA5, count: chunkSize)

  /// The commit response for the large fixture, uploaded whole.
  private static var largeFileMetadataJSON: String {
    fileMetadataJSON(
      name: "big.bin",
      rev: revision,
      size: largeFileSize,
      contentHash: hash(of: largeFileData).rawValue
    )
  }

  private static var uploadPath: NormalizedDropboxPath {
    get throws { try DropboxPath(validating: "/big.bin").normalized }
  }

  // MARK: Helpers

  private static func makeClient() async -> (mock: MockTransport, client: DropboxClient) {
    let mock = MockTransport()
    return (mock, await makeLinkedClient(transport: mock))
  }

  private static func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("TransferTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func patternedData(count: Int) -> Data {
    Data((0..<count).lazy.map { UInt8(truncatingIfNeeded: $0) })
  }

  /// The bytes of the large fixture's chunk at `index`, split as the uploader splits.
  private static func chunk(_ index: Int) -> Data {
    let start = index * chunkSize
    return largeFileData.subdata(in: start..<min(start + chunkSize, largeFileData.count))
  }

  private static func hash(of data: Data) -> ContentHash {
    var hasher = DropboxContentHasher()
    hasher.update(data)
    return hasher.finalize()
  }

  private static func fileMetadataJSON(
    name: String,
    rev: String,
    size: Int,
    contentHash: String
  ) -> String {
    #"""
    {"id":"id:testfileid001","name":"\#(name)","path_lower":"/\#(name.lowercased())","path_display":"/\#(name)","client_modified":"\#(clientModifiedISO)","server_modified":"\#(serverModifiedISO)","rev":"\#(rev)","size":\#(size),"is_downloadable":true,"content_hash":"\#(contentHash)"}
    """#
  }

  private static func apiArgument(of request: URLRequest) throws -> [String: Any] {
    let header = try #require(request.value(forHTTPHeaderField: "Dropbox-API-Arg"))
    return try #require(JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any])
  }

  private static func cursor(in argument: [String: Any]) throws -> (sessionID: String, offset: Int)
  {
    let cursor = try #require(argument["cursor"] as? [String: Any])
    return (
      sessionID: try #require(cursor["session_id"] as? String),
      offset: try #require(cursor["offset"] as? Int)
    )
  }

  /// The checkpoint an interrupted upload of the large fixture would have
  /// left behind after `upload_session/start` was acknowledged.
  private static func checkpointAfterFirstChunk(
    prefixHash: ContentHash? = nil,
    startedAt: Date = Date()
  ) throws -> UploadSessionRecord {
    try uploadSession(
      path: "/big.bin",
      sessionID: "sess1",
      committedOffset: UInt64(chunkSize),
      prefixHash: prefixHash ?? hash(of: chunk(0)),
      startedAt: startedAt
    )
  }

  private static func appendOneByte(to url: URL) {
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data([0]))
  }

  // MARK: FileUploader

  @Test
  func `small upload commits in one request with full arguments`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("small.bin")
    let content = Self.patternedData(count: Self.smallFileSize)
    try content.write(to: fileURL)
    let expectedHash = try DropboxContentHasher.hash(contentsOf: fileURL)

    let (mock, client) = await Self.makeClient()
    await mock.enqueueJSON(
      Self.fileMetadataJSON(
        name: "small.bin",
        rev: Self.revision,
        size: Self.smallFileSize,
        contentHash: expectedHash.rawValue
      )
    )

    let revision = try FileRevision(validating: Self.revision)
    let metadata = try await FileUploader(client: client).upload(
      fileURL,
      to: try DropboxPath(validating: "/small.bin"),
      mode: .update(revision)
    )

    let requests = await mock.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://content.dropboxapi.com/2/files/upload")
    #expect(request.httpBody == content)

    let argument = try Self.apiArgument(of: request)
    #expect(argument["path"] as? String == "/small.bin")
    let mode = try #require(argument["mode"] as? [String: Any])
    #expect(mode[".tag"] as? String == "update")
    #expect(mode["update"] as? String == Self.revision)
    #expect(argument["autorename"] as? Bool == true)
    let clientModified = try #require(argument["client_modified"] as? String)
    #expect(ISO8601DateFormatter().date(from: clientModified) != nil)
    #expect(argument["content_hash"] as? String == expectedHash.rawValue)
    #expect(metadata.rev == revision)
  }

  @Test
  func `large upload runs session with per chunk cursors and hashes`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("big.bin")
    try Self.largeFileData.write(to: fileURL)

    let (mock, client) = await Self.makeClient()
    await mock.enqueueJSON(#"{"session_id":"sess1"}"#)
    await mock.enqueue(MockTransport.Exchange())
    await mock.enqueueJSON(
      Self.fileMetadataJSON(
        name: "big.bin",
        rev: Self.revision,
        size: Self.largeFileSize,
        contentHash: Self.hash(of: Self.largeFileData).rawValue
      )
    )

    _ = try await FileUploader(client: client).upload(
      fileURL,
      to: try DropboxPath(validating: "/big.bin"),
      mode: .add
    )

    let requests = await mock.requests
    #expect(
      requests.map { $0.url?.absoluteString } == [
        "https://content.dropboxapi.com/2/files/upload_session/start",
        "https://content.dropboxapi.com/2/files/upload_session/append_v2",
        "https://content.dropboxapi.com/2/files/upload_session/finish"
      ]
    )
    try #require(requests.count == 3)

    let firstChunk = Self.chunk(0)
    let start = try Self.apiArgument(of: requests[0])
    #expect(requests[0].httpBody == firstChunk)
    #expect(requests[0].httpBody?.count == Self.chunkSize)
    #expect(start["content_hash"] as? String == Self.hash(of: firstChunk).rawValue)

    let secondChunk = Self.chunk(1)
    let append = try Self.apiArgument(of: requests[1])
    let appendCursor = try Self.cursor(in: append)
    #expect(appendCursor.sessionID == "sess1")
    #expect(appendCursor.offset == Self.chunkSize)
    #expect(requests[1].httpBody == secondChunk)
    #expect(append["content_hash"] as? String == Self.hash(of: secondChunk).rawValue)

    let finalChunk = Self.chunk(2)
    let finish = try Self.apiArgument(of: requests[2])
    let finishCursor = try Self.cursor(in: finish)
    #expect(finishCursor.sessionID == "sess1")
    #expect(finishCursor.offset == 2 * Self.chunkSize)
    #expect(requests[2].httpBody == finalChunk)
    #expect(requests[2].httpBody?.count == Self.largeFileSize - 2 * Self.chunkSize)
    #expect(finish["content_hash"] as? String == Self.hash(of: finalChunk).rawValue)
    let commit = try #require(finish["commit"] as? [String: Any])
    #expect(commit["path"] as? String == "/big.bin")
  }

  @Test
  func `incorrect offset seeks back and resends from server offset`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("big.bin")
    try Self.largeFileData.write(to: fileURL)

    let (mock, client) = await Self.makeClient()
    await mock.enqueueJSON(#"{"session_id":"sess1"}"#)
    await mock.enqueueJSON(
      #"{"error":{".tag":"incorrect_offset","correct_offset":4194304},"error_summary":"incorrect_offset/"}"#,
      status: 409
    )
    await mock.enqueue(MockTransport.Exchange())
    await mock.enqueueJSON(
      Self.fileMetadataJSON(
        name: "big.bin",
        rev: Self.revision,
        size: Self.largeFileSize,
        contentHash: Self.hash(of: Self.largeFileData).rawValue
      )
    )

    _ = try await FileUploader(client: client).upload(
      fileURL,
      to: try DropboxPath(validating: "/big.bin"),
      mode: .add
    )

    let requests = await mock.requests
    try #require(requests.count == 4)
    #expect(
      requests[2].url?.absoluteString
        == "https://content.dropboxapi.com/2/files/upload_session/append_v2"
    )

    // Recovery seeks the file handle back to the server's offset and resends
    // the chunk read from there.
    let retriedCursor = try Self.cursor(in: Self.apiArgument(of: requests[2]))
    #expect(retriedCursor.offset == Self.chunkSize)
    #expect(requests[2].httpBody == Self.chunk(1))

    let finishCursor = try Self.cursor(in: Self.apiArgument(of: requests[3]))
    #expect(finishCursor.offset == 2 * Self.chunkSize)
  }

  @Test
  func `file mutation during session aborts before next chunk`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("big.bin")
    try Self.largeFileData.write(to: fileURL)

    let (mock, client) = await Self.makeClient()
    await mock.enqueueJSON(#"{"session_id":"sess1"}"#)
    // The abort also closes the abandoned session with an empty append.
    await mock.enqueue(MockTransport.Exchange())
    await mock.setRequestHook { request in
      guard request.url?.absoluteString.hasSuffix("upload_session/start") == true else { return }
      Self.appendOneByte(to: fileURL)
    }

    let failure = await #expect(throws: ItemSyncFailure.self) {
      _ = try await FileUploader(client: client).upload(
        fileURL,
        to: try DropboxPath(validating: "/big.bin"),
        mode: .add
      )
    }

    guard case .dataChanged(let path) = try #require(failure) else {
      Issue.record("Expected dataChanged, got \(String(describing: failure))")
      return
    }
    #expect(path == "/big.bin")
    let requests = await mock.requests
    try #require(requests.count == 2)
    let close = try Self.apiArgument(of: requests[1])
    #expect(close["close"] as? Bool == true)
    #expect(requests[1].httpBody?.isEmpty ?? true)
  }

  // MARK: Resumable upload sessions

  @Test
  func `resumes a checkpointed session without resending committed chunks`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("big.bin")
    try Self.largeFileData.write(to: fileURL)
    let (store, storeDirectory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: storeDirectory) }
    try await store.recordUploadSession(Self.checkpointAfterFirstChunk())

    let (mock, client) = await Self.makeClient()
    // The probe, the second chunk, and the commit.
    await mock.enqueue(MockTransport.Exchange())
    await mock.enqueue(MockTransport.Exchange())
    await mock.enqueueJSON(Self.largeFileMetadataJSON)

    _ = try await FileUploader(client: client, checkpointingInto: store).upload(
      fileURL,
      to: try DropboxPath(validating: "/big.bin"),
      mode: .add
    )

    let requests = await mock.requests
    #expect(
      requests.map { $0.url?.absoluteString } == [
        "https://content.dropboxapi.com/2/files/upload_session/append_v2",
        "https://content.dropboxapi.com/2/files/upload_session/append_v2",
        "https://content.dropboxapi.com/2/files/upload_session/finish"
      ]
    )
    try #require(requests.count == 3)

    // Nothing already committed is resent: the probe carries no bytes and the
    // first real request is the chunk after the checkpoint.
    #expect(requests[0].httpBody?.isEmpty ?? true)
    #expect(try Self.cursor(in: Self.apiArgument(of: requests[0])).offset == Self.chunkSize)
    #expect(requests[1].httpBody == Self.chunk(1))
    #expect(try Self.cursor(in: Self.apiArgument(of: requests[1])).sessionID == "sess1")
    #expect(try Self.cursor(in: Self.apiArgument(of: requests[2])).offset == 2 * Self.chunkSize)

    // A committed upload leaves nothing to resume.
    #expect(try await store.resumableUploadSession(forPath: Self.uploadPath) == nil)
  }

  @Test
  func `a checkpoint past the session window starts over`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("big.bin")
    try Self.largeFileData.write(to: fileURL)
    let (store, storeDirectory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: storeDirectory) }
    try await store.recordUploadSession(
      Self.checkpointAfterFirstChunk(
        startedAt: Date(timeIntervalSinceNow: -UploadSessionRecord.sessionWindow - 60)
      )
    )

    let (mock, client) = await Self.makeClient()
    await mock.enqueueJSON(#"{"session_id":"sess2"}"#)
    await mock.enqueue(MockTransport.Exchange())
    await mock.enqueueJSON(Self.largeFileMetadataJSON)

    _ = try await FileUploader(client: client, checkpointingInto: store).upload(
      fileURL,
      to: try DropboxPath(validating: "/big.bin"),
      mode: .add
    )

    // A session Dropbox has already forgotten is never probed: the upload
    // opens a new one and sends the file from the start.
    let requests = await mock.requests
    try #require(requests.count == 3)
    #expect(
      requests[0].url?.absoluteString
        == "https://content.dropboxapi.com/2/files/upload_session/start"
    )
    #expect(requests[0].httpBody == Self.chunk(0))
  }

  @Test
  func `a checkpoint whose content no longer matches starts over`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("big.bin")
    try Self.largeFileData.write(to: fileURL)
    let (store, storeDirectory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: storeDirectory) }
    // The recorded prefix hash belongs to bytes this file does not begin with.
    try await store.recordUploadSession(
      Self.checkpointAfterFirstChunk(prefixHash: Self.hash(of: Self.someOtherFileData))
    )

    let (mock, client) = await Self.makeClient()
    await mock.enqueue(MockTransport.Exchange())
    await mock.enqueueJSON(#"{"session_id":"sess2"}"#)
    await mock.enqueue(MockTransport.Exchange())
    await mock.enqueueJSON(Self.largeFileMetadataJSON)

    _ = try await FileUploader(client: client, checkpointingInto: store).upload(
      fileURL,
      to: try DropboxPath(validating: "/big.bin"),
      mode: .add
    )

    // Dropbox still held the session, but nothing proves it holds these
    // bytes, so the upload starts over rather than splicing two files.
    let requests = await mock.requests
    try #require(requests.count == 4)
    #expect(
      requests[1].url?.absoluteString
        == "https://content.dropboxapi.com/2/files/upload_session/start"
    )
    #expect(requests[1].httpBody == Self.chunk(0))
  }

  @Test
  func `a checkpoint records only what the server acknowledged`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("big.bin")
    try Self.largeFileData.write(to: fileURL)
    let (store, storeDirectory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: storeDirectory) }

    let (mock, client) = await Self.makeClient()
    await mock.enqueueJSON(#"{"session_id":"sess1"}"#)
    await mock.enqueueJSON(
      #"{"error":{".tag":"lookup_failed","lookup_failed":{".tag":"not_found"}},"error_summary":"lookup_failed/not_found/"}"#,
      status: 409
    )

    await #expect(throws: ItemSyncFailure.self) {
      _ = try await FileUploader(client: client, checkpointingInto: store).upload(
        fileURL,
        to: try DropboxPath(validating: "/big.bin"),
        mode: .add
      )
    }

    // The second chunk was read and sent but never acknowledged, so the
    // checkpoint still stands at the one chunk `upload_session/start` took.
    let recorded = try #require(try await store.resumableUploadSession(forPath: Self.uploadPath))
    #expect(recorded.sessionID.rawValue == "sess1")
    #expect(recorded.committedOffset == UInt64(Self.chunkSize))
    #expect(recorded.prefixHash == Self.hash(of: Self.chunk(0)))
  }

  // MARK: FileDownloader

  @Test
  func `download verifies places and backdates the file`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("hello.txt")
    let body = Data("hello zephyr".utf8)
    let contentHash = Self.hash(of: body)

    let (mock, client) = await Self.makeClient()
    await mock.enqueue(
      MockTransport.Exchange(
        headers: [
          "Dropbox-API-Result": Self.fileMetadataJSON(
            name: "hello.txt",
            rev: Self.revision,
            size: body.count,
            contentHash: contentHash.rawValue
          )
        ],
        body: body
      )
    )

    let revision = try FileRevision(validating: Self.revision)
    let metadata = try await FileDownloader(client: client).download(
      .revision(revision),
      to: destination
    )

    #expect(try Data(contentsOf: destination) == body)
    #expect(metadata.contentHash == contentHash)

    // The placed file's mtime is the earlier of the fixture's client- and
    // server-modified dates (here, server_modified).
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect(attributes[.modificationDate] as? Date == Self.serverModified)

    let requests = await mock.requests
    try #require(requests.count == 1)
    #expect(requests[0].url?.absoluteString == "https://content.dropboxapi.com/2/files/download")
    let argument = try Self.apiArgument(of: requests[0])
    #expect(argument["path"] as? String == "rev:\(Self.revision)")
  }

  @Test
  func `download retries when content fails hash verification`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("hello.txt")
    let body = Data("hello zephyr".utf8)
    let contentHash = Self.hash(of: body)
    let resultHeader = [
      "Dropbox-API-Result": Self.fileMetadataJSON(
        name: "hello.txt",
        rev: Self.revision,
        size: body.count,
        contentHash: contentHash.rawValue
      )
    ]

    let (mock, client) = await Self.makeClient()
    await mock.enqueue(
      MockTransport.Exchange(
        headers: resultHeader,
        body: Data("corrupted".utf8)
      )
    )
    await mock.enqueue(MockTransport.Exchange(headers: resultHeader, body: body))

    let metadata = try await FileDownloader(client: client).download(
      .revision(try FileRevision(validating: Self.revision)),
      to: destination
    )

    #expect(try Data(contentsOf: destination) == body)
    #expect(metadata.contentHash == contentHash)
    #expect(await mock.requests.count == 2)
  }

  @Test
  func `transient chunk corruption retries the chunk`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("big.bin")
    try Self.largeFileData.write(to: fileURL)

    let (mock, client) = await Self.makeClient()
    await mock.enqueueJSON(#"{"session_id":"sess1"}"#)
    await mock.enqueue(
      MockTransport.Exchange(
        status: 409,
        body: Data(
          #"{"error_summary":"content_hash_mismatch/..","error":{".tag":"content_hash_mismatch"}}"#
            .utf8
        )
      )
    )
    await mock.enqueue(MockTransport.Exchange())
    await mock.enqueueJSON(
      Self.fileMetadataJSON(
        name: "big.bin",
        rev: Self.revision,
        size: Self.largeFileSize,
        contentHash: Self.hash(of: Self.largeFileData).rawValue
      )
    )

    _ = try await FileUploader(client: client).upload(
      fileURL,
      to: try DropboxPath(validating: "/big.bin"),
      mode: .add
    )

    // start, failed append, retried append, finish — the same chunk resent.
    let requests = await mock.requests
    try #require(requests.count == 4)
    #expect(requests[1].httpBody == requests[2].httpBody)
    let retried = try Self.cursor(in: try Self.apiArgument(of: requests[2]))
    #expect(retried.offset == Self.chunkSize)
  }

  @Test
  func `downloader refuses a directory destination`() async throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let (_, client) = await Self.makeClient()
    await #expect(throws: ItemSyncFailure.self) {
      _ = try await FileDownloader(client: client).download(
        .path(try DropboxPath(validating: "/whatever.txt")),
        to: directory
      )
    }
  }
}
