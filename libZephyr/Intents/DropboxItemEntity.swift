import AppIntents
import Foundation

/// A file or folder in a Dropbox account, as a shortcut names one.
public struct DropboxItemEntity: AppEntity {
  /// The name Shortcuts gives this kind of value.
  ///
  /// `numericFormat` takes a literal rather than the framework's own bundle:
  /// App Intents folds it at build time and rejects anything it cannot read
  /// as a constant, `bundle:` included. The extractor writes it into this
  /// target's catalog regardless, so nothing is lost but the symmetry.
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource("Dropbox Item", bundle: .libZephyr),
    numericFormat: "\(placeholder: .int) Dropbox items"
  )

  /// Where Shortcuts looks items up.
  public static let defaultQuery = DropboxItemQuery()

  /// The account holding the item, and Dropbox's identifier for it.
  public let id: DropboxItemID

  /// The item's own name.
  @Property(title: LocalizedStringResource("Name", bundle: .libZephyr))
  public var name: String

  /// Where the item sits in the account, as the reader sees it written.
  @Property(title: LocalizedStringResource("Path", bundle: .libZephyr))
  public var path: String

  /// Whether the item is a folder.
  @Property(title: LocalizedStringResource("Folder", bundle: .libZephyr))
  public var isFolder: Bool

  /// The item's size, or `nil` for a folder.
  @Property(title: LocalizedStringResource("Size", bundle: .libZephyr))
  public var size: Measurement<UnitInformationStorage>?

  /// When Dropbox last saw the item change.
  @Property(title: LocalizedStringResource("Modified", bundle: .libZephyr))
  public var modificationDate: Date?

  /// The account holding the item, by name.
  @Property(title: LocalizedStringResource("Account", bundle: .libZephyr))
  public var accountName: String

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(path)")
  }

  /// Describes an item the index holds.
  public init(_ record: IndexEntryRecord, in account: AccountConfiguration) {
    id = DropboxItemID(account: account.accountID, item: record.dbxID)
    name = record.name
    path = record.pathCased.displayPath
    isFolder = record.itemType == .folder
    size = record.size.map { Measurement(value: Double($0), unit: .bytes) }
    modificationDate = record.serverModified ?? record.clientModified
    accountName = account.displayName
  }

  /**
   Describes a file Dropbox has just reported.

   An upload or a restore answers with a file the index has not seen yet — the
   change feed reaches it seconds later — so the intent that made it describes
   it from what Dropbox said rather than waiting for the index to catch up.
   */
  public init(_ metadata: FileMetadata, in account: AccountConfiguration) {
    id = DropboxItemID(account: account.accountID, item: metadata.id)
    name = metadata.name
    path = metadata.pathDisplay?.displayPath ?? metadata.name
    isFolder = false
    size = Measurement(value: Double(metadata.size), unit: .bytes)
    modificationDate = metadata.serverModified
    accountName = account.displayName
  }
}
