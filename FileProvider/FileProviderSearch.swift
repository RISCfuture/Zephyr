// FileProvider vends no Sendable annotations, so this import has to be
// `@preconcurrency` to build under Swift 6. That suppresses concurrency
// checking across it, and `@unsafe` owns the data-race risk the suppression
// carries — only an audited SDK removes it.
@unsafe @preconcurrency import FileProvider
import Foundation
import libZephyr
import os
import UniformTypeIdentifiers

/// Answers one search typed into Finder's search box from the sync index.
///
/// The index describes the whole account, so a file nothing has ever
/// downloaded is found exactly like a materialized one and the search costs
/// no network.
final class SearchEnumerator: NSObject, NSFileProviderSearchEnumerator {
  private let query: String
  private let adapterBox: AdapterBox
  private let read = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

  init(request: NSFileProviderStringSearchRequest, adapterBox: AdapterBox) {
    query = request.query
    self.adapterBox = adapterBox
    super.init()
  }

  /**
   How many rows to ask the index for.

   `desiredNumberOfResults` is a hint about how much work is worth doing, not
   a ceiling — the system is free to ask for more, and asks by requesting
   another page. A search answered in one page has no second page to give, so
   honouring the hint as a limit would lose every match past it with nothing
   to say so. The page is filled to what the observer accepts instead, and the
   ranking decides which matches earn the room.

   - Parameter maximum: The most results the observer accepts in one page. It
     is a hard ceiling: the system kills the extension process over a page
     that exceeds it, and an observer that accepts nothing is answered with
     nothing.
   */
  private static func resultLimit(perPageMaximum maximum: Int) -> UInt {
    UInt(max(maximum, 0))
  }

  /// Cancels the index read in flight. Finder asks again on every keystroke
  /// and abandons the enumerator it asked before, so the read for a query the
  /// user has already moved past must not go on holding the index.
  func invalidate() {
    read.withLock { task in
      task?.cancel()
      task = nil
    }
  }

  /// Answers with one page: the most relevant matches the index holds, as
  /// many of them as the observer will accept in a page. `IndexQuery` ranks
  /// over every match rather than over a window of them, so the first page
  /// is the answer.
  func enumerateSearchResults(
    for observer: any NSFileProviderSearchEnumerationObserver,
    startingAt _: NSFileProviderPage?
  ) {
    let limit = Self.resultLimit(perPageMaximum: observer.maximumNumberOfResultsPerPage)
    let task = Task { [adapterBox, query] in
      do {
        let found = try await adapterBox.adapter().items(named: query, limit: limit)
        if !found.isEmpty {
          observer.didEnumerate(found.map(ProviderSearchResult.init(record:)))
        }
        observer.finishEnumerating(upTo: nil)
      } catch {
        ZephyrLog.provider.error(
          "Search enumeration failed: \(String(describing: error), privacy: .private)"
        )
        observer.finishEnumeratingWithError(mapToFileProviderError(error))
      }
    }
    read.withLock { $0 = task }
  }
}

/// One indexed item presented to the system as a search result.
///
/// A result is identified, named, and typed, but unlike `ProviderItem` it is
/// not parented: the system resolves a result it cares about through
/// ``ProviderAdapter/item(for:)``, so a search spends no index lookup
/// resolving a parent for every row it answers with.
final class ProviderSearchResult: NSObject, NSFileProviderSearchResult, Sendable {
  private let identifierRawValue: String
  private let storedFilename: String
  private let storedContentType: UTType
  private let storedContentModificationDate: Date?
  private let storedLastUsedDate: Date?
  private let storedSize: UInt64?

  /// The Dropbox file identifier, which is also the item's File Provider
  /// identifier — the system resolves a result through it.
  var itemIdentifier: NSFileProviderItemIdentifier {
    NSFileProviderItemIdentifier(identifierRawValue)
  }

  /// The item's display name — the cased final path component.
  var filename: String { storedFilename }

  /// Nothing: Dropbox reports no creation date, and the modification dates it
  /// does report are a different fact than when the file came into being.
  var creationDate: Date? { nil }

  /// The last content modification date Dropbox recorded for the file.
  var contentModificationDate: Date? { storedContentModificationDate }

  /// The system-reported last-used date, when the system set one.
  var lastUsedDate: Date? { storedLastUsedDate }

  /// The same type the item itself reports, so Finder sorts and filters a
  /// result the way it does the file.
  var contentType: UTType { storedContentType }

  /// The file's size in bytes; `nil` for folders.
  var documentSize: NSNumber? { storedSize.map { NSNumber(value: $0) } }

  /// Creates the search result presenting an index row.
  init(record: IndexEntryRecord) {
    identifierRawValue = record.dbxID.rawValue
    storedFilename = record.name
    storedContentType = ProviderItem.contentType(for: record)
    storedContentModificationDate = record.clientModified
    storedLastUsedDate = record.lastUsedDate
    storedSize = record.itemType == .folder ? nil : record.size
    super.init()
  }
}
