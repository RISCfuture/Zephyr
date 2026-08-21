import FileProvider
import Foundation
import System
import UniformTypeIdentifiers

/**
 The File Provider representation of one indexed Dropbox item.

 Maps an ``IndexEntryRecord`` onto `NSFileProviderItem`: the Dropbox file identifier
 becomes the item identifier, the content hash becomes the content version, and the
 index's metadata generation becomes the metadata version. Items are immutable
 snapshots.
 */
public final class ProviderItem: NSObject, NSFileProviderItemDecorating, Sendable {
  /**
   The decoration Finder badges an ignored item with.

   Declared in the File Provider extension's `Info.plist` under
   `NSFileProviderDecorations`; the two spellings must agree or the system
   drops the decoration silently.
   */
  public static let ignoredDecoration = NSFileProviderItemDecorationIdentifier(
    "codes.tim.Zephyr.ignored"
  )

  private static let rootFilename = "Dropbox"
  private static let folderContentVersion = Data("folder".utf8)
  private static let metadataVersionByteCount = 8
  private static let fileCapabilities: NSFileProviderItemCapabilities = [
    .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting,
    .allowsDeleting
  ]
  private static let folderCapabilities: NSFileProviderItemCapabilities = [
    .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
    .allowsRenaming, .allowsReparenting, .allowsDeleting
  ]
  /// Symlink contents cannot be rewritten through the Dropbox API.
  private static let symlinkCapabilities: NSFileProviderItemCapabilities = [
    .allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting
  ]
  private static let rootCapabilities: NSFileProviderItemCapabilities = [
    .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems
  ]

  /// The item presented for the domain's root container: a read-only folder named "Dropbox".
  public static let root = ProviderItem()

  private let identifierRawValue: String
  private let parentIdentifierRawValue: String
  private let itemType: IndexItemType
  private let storedFilename: String
  private let storedContentType: UTType
  private let storedContentVersion: Data
  private let storedMetadataVersion: Data
  private let storedSymlinkTargetPath: String?
  private let storedSize: UInt64?
  private let storedContentModificationDate: Date?
  private let storedTagData: Data?
  private let storedLastUsedDate: Date?
  private let storedExtendedAttributes: [String: Data]?
  private let storedIgnored: Bool
  private let isRoot: Bool

  /// The stable identifier of this item — the Dropbox file identifier's raw string.
  public var itemIdentifier: NSFileProviderItemIdentifier {
    NSFileProviderItemIdentifier(identifierRawValue)
  }

  /// The identifier of the containing folder's item.
  public var parentItemIdentifier: NSFileProviderItemIdentifier {
    NSFileProviderItemIdentifier(parentIdentifierRawValue)
  }

  /// The item's display name — the cased final path component.
  public var filename: String { storedFilename }

  /// The item's type: `.folder`, `.symbolicLink`, or a type inferred from the filename extension.
  public var contentType: UTType { storedContentType }

  /// The content and metadata versions backing File Provider change detection.
  public var itemVersion: NSFileProviderItemVersion {
    NSFileProviderItemVersion(
      contentVersion: storedContentVersion,
      metadataVersion: storedMetadataVersion
    )
  }

  /// What the system may do with the item; the domain root cannot itself be
  /// renamed, moved, or deleted.
  public var capabilities: NSFileProviderItemCapabilities {
    if isRoot { return Self.rootCapabilities }
    switch itemType {
      case .folder: return Self.folderCapabilities
      case .symlink: return Self.symlinkCapabilities
      case .file: return Self.fileCapabilities
    }
  }

  /// Finder tag data the system asked the provider to persist.
  public var tagData: Data? { storedTagData }

  /// The system-reported last-used date, when the system set one.
  public var lastUsedDate: Date? { storedLastUsedDate }

  /// Extended attributes persisted for the item, echoed back so the system
  /// keeps them on the local replica.
  public var extendedAttributes: [String: Data] { storedExtendedAttributes ?? [:] }

  /**
   State the custom actions' activation predicates test: whether the item
   carries the `com.dropbox.ignored` marker, and whether it is a plain file.

   A predicate has no other way to tell a file from a folder. `capabilities`
   cannot: `allowsContentEnumerating` and `allowsReading` are the same bit, as
   are `allowsAddingSubItems` and `allowsWriting`, so `fileCapabilities` and
   `folderCapabilities` are numerically equal. `typeIdentifier` is
   unavailable on macOS, and `contentType` is not part of what a predicate is
   evaluated against.

   A flag rather than the item type, because the one question anything asks
   here is whether an action that only makes sense for a file may run — and
   this answers `false` for a symlink too, whose contents Dropbox will not let
   Zephyr rewrite.
   */
  public var userInfo: [AnyHashable: Any]? {
    ["ignored": storedIgnored, "isFile": itemType == .file]
  }

  /// Badges an ignored item, so its state reads from the Finder window
  /// rather than only from the context menu.
  public var decorations: [NSFileProviderItemDecorationIdentifier]? {
    storedIgnored ? [Self.ignoredDecoration] : nil
  }

  /// The file's size in bytes; `nil` for folders.
  public var documentSize: NSNumber? {
    storedSize.map { NSNumber(value: $0) }
  }

  /// The last content modification date Dropbox recorded for the file.
  public var contentModificationDate: Date? { storedContentModificationDate }

  /// The target path of a symbolic link; `nil` for other item types.
  public var symlinkTargetPath: String? { storedSymlinkTargetPath }

  /**
   Creates the File Provider representation of an index row.

   - Parameters:
     - record: The index row to present.
     - parentIdentifier: The identifier of the containing item, already resolved by the caller.
   */
  public init(record: IndexEntryRecord, parentIdentifier: NSFileProviderItemIdentifier) {
    identifierRawValue = record.dbxID.rawValue
    parentIdentifierRawValue = parentIdentifier.rawValue
    itemType = record.itemType
    storedFilename = record.name
    storedContentType = Self.contentType(for: record)
    storedContentVersion = Self.contentVersion(for: record)
    storedMetadataVersion = Self.metadataVersion(for: record.metaGeneration)
    storedSymlinkTargetPath = record.symlinkTarget
    storedSize = record.itemType == .folder ? nil : record.size
    storedContentModificationDate = record.clientModified
    storedTagData = record.tagData
    storedLastUsedDate = record.lastUsedDate
    storedExtendedAttributes = record.xattrs
    storedIgnored = record.ignored
    isRoot = false
  }

  override private init() {
    identifierRawValue = NSFileProviderItemIdentifier.rootContainer.rawValue
    parentIdentifierRawValue = NSFileProviderItemIdentifier.rootContainer.rawValue
    itemType = .folder
    storedFilename = Self.rootFilename
    storedContentType = .folder
    storedContentVersion = Self.folderContentVersion
    storedMetadataVersion = Data(count: Self.metadataVersionByteCount)
    storedSymlinkTargetPath = nil
    storedSize = nil
    storedContentModificationDate = nil
    storedTagData = nil
    storedLastUsedDate = nil
    storedExtendedAttributes = nil
    storedIgnored = false
    isRoot = true
  }

  private static func contentType(for record: IndexEntryRecord) -> UTType {
    switch record.itemType {
      case .folder: .folder
      case .symlink: .symbolicLink
      case .file: fileContentType(forFilename: record.name)
    }
  }

  private static func fileContentType(forFilename filename: String) -> UTType {
    guard let fileExtension = FilePath(filename).extension, !fileExtension.isEmpty else {
      return .data
    }
    return UTType(filenameExtension: fileExtension) ?? .data
  }

  private static func contentVersion(for record: IndexEntryRecord) -> Data {
    guard record.itemType != .folder else { return folderContentVersion }
    return record.contentHash.map { Data($0.rawValue.utf8) } ?? Data()
  }

  private static func metadataVersion(for generation: Int64) -> Data {
    withUnsafeBytes(of: generation.littleEndian) { Data($0) }
  }
}
