import Foundation

/**
 A lazily-paged folder listing: each page of `files/list_folder` is fetched
 only when iteration consumes past the previous one, so slow consumers never
 buffer the whole (possibly recursive) listing in memory.
 */
public struct ListFolderSequence: AsyncSequence, Sendable {
  public typealias Element = ItemMetadata

  let client: DropboxClient
  let path: DropboxPath
  let recursive: Bool
  let includeDeleted: Bool

  public func makeAsyncIterator() -> Iterator {
    Iterator(client: client, path: path, recursive: recursive, includeDeleted: includeDeleted)
  }

  public struct Iterator: AsyncIteratorProtocol {
    private let client: DropboxClient
    private let path: DropboxPath
    private let recursive: Bool
    private let includeDeleted: Bool
    private var buffer: [ItemMetadata] = []
    private var position = 0
    private var cursor: DeltaCursor?
    private var exhausted = false

    init(client: DropboxClient, path: DropboxPath, recursive: Bool, includeDeleted: Bool) {
      self.client = client
      self.path = path
      self.recursive = recursive
      self.includeDeleted = includeDeleted
    }

    public mutating func next() async throws -> ItemMetadata? {
      while position >= buffer.count {
        guard !exhausted else { return nil }
        let page: ListFolderPage =
          if let cursor {
            try await client.listFolderContinue(from: cursor)
          } else {
            try await client.listFolder(
              path,
              recursive: recursive,
              includeDeleted: includeDeleted
            )
          }
        buffer = page.entries
        position = 0
        cursor = page.cursor
        exhausted = !page.hasMore
      }
      defer { position += 1 }
      return buffer[position]
    }
  }
}
