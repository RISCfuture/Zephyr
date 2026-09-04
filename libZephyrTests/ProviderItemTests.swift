import FileProvider
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import libZephyr

@Suite
struct ProviderItemTests {
  private func record(
    id: String = "id:item1",
    path: String = "/Docs/report.txt",
    itemType: IndexItemType = .file,
    hash: String? = String(repeating: "ab", count: 32),
    symlinkTarget: String? = nil,
    size: UInt64? = 42,
    metaGeneration: Int64 = 0
  ) throws -> IndexEntryRecord {
    let display = try DropboxPath(validating: path)
    return IndexEntryRecord(
      dbxID: try DropboxFileIdentifier(validating: id),
      pathNormalized: display.normalized,
      parentPathNormalized: display.normalized.parent,
      pathCased: display,
      name: display.basename,
      itemType: itemType,
      revision: itemType == .folder ? nil : try FileRevision(validating: "015d1a1f3f2e5c0"),
      contentHash: try hash.map { try ContentHash(validating: $0) },
      symlinkTarget: symlinkTarget,
      size: size,
      clientModified: Date(timeIntervalSince1970: 1_000_000),
      serverModified: Date(timeIntervalSince1970: 1_000_100),
      metaGeneration: metaGeneration
    )
  }

  private func item(for record: IndexEntryRecord) -> ProviderItem {
    ProviderItem(record: record, parentIdentifier: .rootContainer)
  }

  @Test
  func `metadata version encodes generation as little endian`() throws {
    let item = item(for: try record(metaGeneration: 0x0102_0304_0506_0708))
    #expect(item.itemVersion.metadataVersion == Data([8, 7, 6, 5, 4, 3, 2, 1]))
  }

  @Test
  func `content version uses hash for files and constant for folders`() throws {
    let hash = String(repeating: "cd", count: 32)
    let file = item(for: try record(hash: hash))
    #expect(file.itemVersion.contentVersion == Data(hash.utf8))

    let folder = item(
      for: try record(path: "/Docs", itemType: .folder, hash: nil, size: nil)
    )
    #expect(folder.itemVersion.contentVersion == Data("folder".utf8))
  }

  @Test
  func `symlinks expose target and symbolic link type`() throws {
    let link = item(
      for: try record(path: "/link", itemType: .symlink, symlinkTarget: "../real.txt")
    )
    #expect(link.symlinkTargetPath == "../real.txt")
    #expect(link.contentType == .symbolicLink)
    #expect(link.itemVersion.contentVersion == Data(String(repeating: "ab", count: 32).utf8))
  }
}
