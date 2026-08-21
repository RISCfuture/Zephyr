import CryptoKit
import Foundation

/**
 An incremental implementation of the Dropbox content-hash algorithm.

 The algorithm splits input into consecutive 4 MiB blocks, hashes each block with
 SHA-256, and feeds every block's raw 32-byte digest into an overall SHA-256.
 Finalizing yields the overall digest as a lowercase hex ``ContentHash``.

 Feed input in chunks of any size with ``update(_:)`` and call ``finalize()`` once
 all input has been consumed. To hash a file on disk without loading it into
 memory, use ``hash(contentsOf:)``.
 */
struct DropboxContentHasher: Sendable {
  private static let blockSize = 4 * 1024 * 1024, readChunkSize = 65536

  private var overallHash = SHA256()
  private var blockHash = SHA256()
  private var bytesInCurrentBlock = 0

  /// Creates a hasher that has consumed no input.
  init() {}

  /**
   Computes the content hash of the file at `url` by streaming it in 64 KiB reads.

   - Parameter url: The location of the file to hash.
   - Returns: The content hash of the file's bytes.
   - Throws: Any I/O error raised while opening or reading the file, unchanged.
   */
  static func hash(contentsOf url: URL) throws -> ContentHash {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }

    var hasher = Self()
    while let chunk = try file.read(upToCount: readChunkSize), !chunk.isEmpty {
      hasher.update(chunk)
    }
    return hasher.finalize()
  }

  private static func lowercaseHex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  /**
   Consumes the next chunk of input.

   Chunks may be any size; the hasher tracks its position within the current
   4 MiB block, so a single chunk may span block boundaries.

   - Parameter data: The next bytes of input.
   */
  mutating func update(_ data: some DataProtocol) {
    var start = data.startIndex
    while start < data.endIndex {
      let capacity = Self.blockSize - bytesInCurrentBlock
      let end = data.index(start, offsetBy: capacity, limitedBy: data.endIndex) ?? data.endIndex
      blockHash.update(data: data[start..<end])
      bytesInCurrentBlock += data.distance(from: start, to: end)
      if bytesInCurrentBlock == Self.blockSize { finishCurrentBlock() }
      start = end
    }
  }

  /// Finalizes the hash over all input consumed so far and returns the content hash.
  consuming func finalize() -> ContentHash {
    if bytesInCurrentBlock > 0 { finishCurrentBlock() }
    return ContentHash(unchecked: Self.lowercaseHex(overallHash.finalize()))
  }

  private mutating func finishCurrentBlock() {
    overallHash.update(data: Data(blockHash.finalize()))
    blockHash = SHA256()
    bytesInCurrentBlock = 0
  }
}
