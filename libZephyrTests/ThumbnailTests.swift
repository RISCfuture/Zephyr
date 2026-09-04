import CoreGraphics
import FileProvider
import Foundation
import Synchronization
import Testing

@testable import libZephyr

@Suite
struct ThumbnailTests {

  // MARK: Static fixtures

  private static let revision = "015d1a1f3f2e5c0000000012a7650"

  private static let fileMetadataJSON = """
    {"id": "id:photo1", "name": "Photo.jpg", "path_lower": "/photo.jpg",
     "path_display": "/Photo.jpg", "client_modified": "2026-02-01T10:00:00Z",
     "server_modified": "2026-02-01T10:00:01Z", "rev": "\(revision)", "size": 42,
     "content_hash": "\(String(repeating: "ab", count: 32))"}
    """

  /// Bytes standing in for a rendered JPEG. Nothing decodes them — the
  /// provider hands them to `fileproviderd` untouched — so any bytes do.
  private static func rendered(_ marker: String) -> Data { Data(marker.utf8) }

  /// A `files/get_thumbnail_batch` reply built from what each entry should
  /// say: bytes for a render, `nil` for a file Dropbox declined.
  private static func batchJSON(_ entries: [Data?]) -> String {
    let encoded = entries.map { data in
      guard let data else {
        return #"{".tag": "failure", "failure": {".tag": "unsupported_extension"}}"#
      }
      return """
        {".tag": "success", "metadata": \(fileMetadataJSON), "thumbnail": \
        "\(data.base64EncodedString())"}
        """
    }
    return #"{"entries": [\#(encoded.joined(separator: ", "))]}"#
  }

  private static func requestBody(of request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  // MARK: Size buckets

  /// A thumbnail that arrives smaller than it will be drawn is visibly soft,
  /// and one that arrives larger only costs bytes — so the bucket has to
  /// cover the request in both axes, not merely come closest to it.
  @Test
  func `a requested size picks the smallest bucket covering it`() {
    #expect(ThumbnailSize.covering(CGSize(width: 32, height: 32)) == .w32h32)
    #expect(ThumbnailSize.covering(CGSize(width: 33, height: 33)) == .w64h64)
    #expect(ThumbnailSize.covering(CGSize(width: 300, height: 300)) == .w480h320)
    // The buckets are not squares, so the smallest one covering a request is
    // not always the next one up: 480×320 is wider than a 400×400 request and
    // still too short for it.
    #expect(ThumbnailSize.covering(CGSize(width: 400, height: 400)) == .w640h480)
    #expect(ThumbnailSize.covering(CGSize(width: 9_000, height: 9_000)) == .w2048h1536)
  }

  // MARK: The route

  @Test
  func `the batch asks by revision and decodes the rendered bytes`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    let bytes = Self.rendered("jpeg-bytes")
    await transport.enqueueJSON(Self.batchJSON([bytes]))

    let revision = try FileRevision(validating: Self.revision)
    let entries = try await client.thumbnails(for: [.revision(revision)], size: .w256h256)

    #expect(entries == [.rendered(bytes)])

    let requests = await transport.requests
    try #require(requests.count == 1)
    #expect(
      requests[0].url?.absoluteString
        == "https://content.dropboxapi.com/2/files/get_thumbnail_batch"
    )
    let body = try Self.requestBody(of: requests[0])
    let sent = try #require(body["entries"] as? [[String: Any]])
    try #require(sent.count == 1)
    // A revision, not a path: it pins the bytes to the version the system
    // will cache them under, and keeps the user's paths out of the request.
    #expect(sent[0]["path"] as? String == "rev:\(Self.revision)")
    #expect(sent[0]["size"] as? String == "w256h256")
    #expect(sent[0]["format"] as? String == "jpeg")
    #expect(sent[0]["mode"] as? String == "bestfit")
  }

  /// One unreadable image must not cost a folder its thumbnails, so a
  /// per-entry failure decodes alongside its neighbours rather than throwing.
  @Test
  func `a thumbnail Dropbox declines leaves the rest of the batch intact`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    let first = Self.rendered("first")
    let last = Self.rendered("last")
    await transport.enqueueJSON(Self.batchJSON([first, nil, last]))

    let revision = try FileRevision(validating: Self.revision)
    let entries = try await client.thumbnails(
      for: Array(repeating: .revision(revision), count: 3),
      size: .w256h256
    )

    #expect(entries == [.rendered(first), .unavailable, .rendered(last)])
  }

  /// The entries come back positionally, so a reply of the wrong length would
  /// silently pair every thumbnail with the wrong file.
  @Test
  func `a reply of the wrong length is refused`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    await transport.enqueueJSON(Self.batchJSON([Self.rendered("only-one")]))

    let revision = try FileRevision(validating: Self.revision)
    await #expect(throws: WireFormatFailure.self) {
      try await client.thumbnails(
        for: Array(repeating: .revision(revision), count: 2),
        size: .w256h256
      )
    }
  }

  // MARK: The adapter

  /// Dropbox renders raster images under 20 MB and nothing else. Learning
  /// that from Dropbox costs a round trip per item; the index already knows
  /// the name and the size, so the answer is free.
  @Test
  func `unrenderable items are answered without asking Dropbox`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyLocalChange([
      .upsert(try fileRecord(id: "id:doc", path: "/Report.pdf")),
      .upsert(try fileRecord(id: "id:huge", path: "/Huge.jpg", size: 30 * 1_024 * 1_024)),
      .upsert(try folderRecord(id: "id:folder", path: "/Pictures"))
    ])
    let (transport, adapter) = await makeAdapter(store: store)

    let answered = Answers()
    // Nothing is enqueued: MockTransport traps on an unexpected request, so
    // finishing at all is the proof that none was made.
    try await adapter.thumbnails(
      for: ["id:doc", "id:huge", "id:folder", "id:missing"].map(
        NSFileProviderItemIdentifier.init(_:)
      ),
      size: CGSize(width: 128, height: 128)
    ) { identifier, data in answered.record(identifier, data) }

    #expect(await transport.requests.isEmpty)
    #expect(answered.count == 4)
    #expect(answered.allNil)
  }

  /// The size the system asks for is a fixed 2048×2048 ceiling rather than
  /// the size the icon gets drawn at — list view's 16-pixel icons ask for it
  /// too — so honoring it literally would spend a full-resolution render on
  /// every thumbnail.
  @Test
  func `the system's ceiling does not buy a full resolution render`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyLocalChange([.upsert(try fileRecord(id: "id:photo", path: "/Photo.jpg"))])
    let (transport, adapter) = await makeAdapter(store: store)
    await transport.enqueueJSON(Self.batchJSON([Self.rendered("jpeg-bytes")]))

    try await adapter.thumbnails(
      for: [NSFileProviderItemIdentifier("id:photo")],
      size: CGSize(width: 2_048, height: 2_048)
    ) { _, _ in }

    let requests = await transport.requests
    try #require(requests.count == 1)
    let body = try Self.requestBody(of: requests[0])
    let sent = try #require(body["entries"] as? [[String: Any]])
    #expect(sent[0]["size"] as? String == "w640h480")
  }

  /// Dropbox renders 25 files per call, and Finder hands over a window's
  /// worth at once.
  @Test
  func `more than twenty five images are paged into separate batches`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var identifiers: [NSFileProviderItemIdentifier] = []
    for index in 0..<30 {
      let id = "id:photo\(index)"
      try await store.applyLocalChange([
        .upsert(
          try fileRecord(
            id: id,
            path: "/Photo\(index).jpg",
            revision: String(format: "015d1a1f3f2e5c00000000%08x", index)
          )
        )
      ])
      identifiers.append(NSFileProviderItemIdentifier(id))
    }
    let (transport, adapter) = await makeAdapter(store: store)
    let bytes = Self.rendered("photo")
    await transport.enqueueJSON(Self.batchJSON(Array(repeating: bytes, count: 25)))
    await transport.enqueueJSON(Self.batchJSON(Array(repeating: bytes, count: 5)))

    let answered = Answers()
    try await adapter.thumbnails(
      for: identifiers,
      size: CGSize(width: 128, height: 128)
    ) { identifier, data in answered.record(identifier, data) }

    #expect(await transport.requests.count == 2)
    #expect(answered.count == 30)
    #expect(answered.allRendered(bytes))
  }

  // MARK: Helpers

  private func makeAdapter(store: SyncIndexStore) async -> (MockTransport, ProviderAdapter) {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    return (
      transport,
      ProviderAdapter(
        store: store,
        client: client,
        scratchDirectory: FileManager.default.temporaryDirectory
      )
    )
  }

  /// What the delivery callback was told, which arrives as each batch lands
  /// rather than all at once.
  private final class Answers: Sendable {
    private let delivered = Mutex<[NSFileProviderItemIdentifier: Data?]>([:])

    var count: Int { delivered.withLock { $0.count } }
    var allNil: Bool { delivered.withLock { $0.values.allSatisfy { $0 == nil } } }

    func record(_ identifier: NSFileProviderItemIdentifier, _ data: Data?) {
      delivered.withLock { $0[identifier] = data }
    }

    func allRendered(_ data: Data) -> Bool {
      delivered.withLock { stored in stored.values.allSatisfy { $0 == data } }
    }
  }
}
