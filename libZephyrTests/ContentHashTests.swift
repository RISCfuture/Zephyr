import CryptoKit
import Foundation
import Testing
@testable import libZephyr

@Suite
struct ContentHashTests {
  private static let blockSize = 4 * 1024 * 1024
  private static let smallInputSize = 1000
  private static let emptyInputHash =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  private static let twoBlockData = patternedData(count: blockSize + 1)

  private static func patternedData(count: Int) -> Data {
    Data((0..<count).lazy.map { UInt8(truncatingIfNeeded: $0) })
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func oneShotHash(of data: Data) -> ContentHash {
    var hasher = DropboxContentHasher()
    hasher.update(data)
    return hasher.finalize()
  }

  @Test
  func emptyInputFinalizesToSHA256OfNothing() {
    #expect(DropboxContentHasher().finalize().rawValue == Self.emptyInputHash)
  }

  @Test
  func partialBlockIsDoubleSHA256() {
    let data = Self.patternedData(count: Self.smallInputSize)
    let expected = Self.hex(SHA256.hash(data: Data(SHA256.hash(data: data))))
    #expect(Self.oneShotHash(of: data).rawValue == expected)
  }

  @Test
  func inputSpanningTwoBlocksMatchesManualComputation() {
    let firstBlockDigest = SHA256.hash(data: Self.twoBlockData.prefix(Self.blockSize))
    let secondBlockDigest = SHA256.hash(data: Self.twoBlockData.suffix(1))
    let expected = Self.hex(SHA256.hash(data: Data(firstBlockDigest) + Data(secondBlockDigest)))
    #expect(Self.oneShotHash(of: Self.twoBlockData).rawValue == expected)
  }

  @Test
  func updatesSplitAtAwkwardOffsetsMatchOneShot() {
    var chunked = DropboxContentHasher()
    chunked.update(Self.twoBlockData.prefix(1))
    chunked.update(Self.twoBlockData.dropFirst(1).prefix(Self.blockSize - 1))
    chunked.update(Self.twoBlockData.suffix(1))
    #expect(chunked.finalize() == Self.oneShotHash(of: Self.twoBlockData))
  }

  @Test
  func fileHashMatchesInMemoryHash() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Self.twoBlockData.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(
      try DropboxContentHasher.hash(contentsOf: url) == Self.oneShotHash(of: Self.twoBlockData)
    )
  }
}
