@preconcurrency import FileProvider
import Foundation
import libZephyr
import os
import UniformTypeIdentifiers

/**
 The replicated File Provider extension serving one linked Dropbox
 account's domain. All logic lives in libZephyr's `ProviderAdapter`;
 this class only bridges the system's completion-handler calls to it.

 `init(domain:)` must never call back into `NSFileProviderManager`: the
 system is waiting on this initializer, and a synchronous round-trip to
 `fileproviderd` deadlocks until the extension is killed.
 */
@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
  private let domain: NSFileProviderDomain
  let adapterBox: AdapterBox
  private let materializedSet: MaterializedSetTracker

  required init(domain: NSFileProviderDomain) {
    // `fileproviderd` builds one of these per linked domain, all in one
    // process; only the first call starts anything.
    CrashReporting.start(as: .fileProvider)
    self.domain = domain
    let rawDomainIdentifier = domain.identifier.rawValue
    let adapterBox = AdapterBox {
      do {
        let account = try AccountIdentifier(providerDomainIdentifier: rawDomainIdentifier)
        let manager = AccountManager(tokenStore: GroupKeychainTokenStore())
        let session = try await manager.session(for: account)
        let adapter = try await session.makeProviderAdapter()
        ZephyrLog.provider.info(
          "Adapter ready for domain \(rawDomainIdentifier, privacy: .private(mask: .hash))"
        )
        return adapter
      } catch {
        ZephyrLog.provider.error(
          """
          Adapter construction failed for domain \
          \(rawDomainIdentifier, privacy: .private(mask: .hash)): \
          \(String(describing: error), privacy: .private)
          """
        )
        throw error
      }
    }
    self.adapterBox = adapterBox
    materializedSet = MaterializedSetTracker(domain: domain, adapterBox: adapterBox)
    super.init()
    ZephyrLog.provider.info(
      "Extension initialized for domain \(rawDomainIdentifier, privacy: .private(mask: .hash))"
    )
  }

  private static func itemVersion(
    contentVersion: Data?,
    metadataVersion: Data?
  ) -> NSFileProviderItemVersion? {
    guard let contentVersion, let metadataVersion else { return nil }
    return NSFileProviderItemVersion(
      contentVersion: contentVersion,
      metadataVersion: metadataVersion
    )
  }

  func invalidate() {
    ZephyrLog.provider.info("Extension invalidated")
    Task { [adapterBox] in await adapterBox.invalidate() }
  }

  func item(
    for identifier: NSFileProviderItemIdentifier,
    request _: NSFileProviderRequest,
    completionHandler: @escaping @Sendable (NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    cancellableTask { [adapterBox] in
      do {
        completionHandler(try await adapterBox.adapter().item(for: identifier), nil)
      } catch {
        completionHandler(nil, mapToFileProviderError(error, failing: .item, on: identifier))
      }
    }
  }

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?,
    request _: NSFileProviderRequest,
    completionHandler: @escaping @Sendable (URL?, NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    let requestedContentVersion = requestedVersion?.contentVersion
    let requestedMetadataVersion = requestedVersion?.metadataVersion
    return cancellableTask { [adapterBox] in
      do {
        let (url, item) = try await adapterBox.adapter().fetchContents(
          for: itemIdentifier,
          requestedVersion: Self.itemVersion(
            contentVersion: requestedContentVersion,
            metadataVersion: requestedMetadataVersion
          )
        )
        completionHandler(url, item, nil)
      } catch {
        completionHandler(
          nil,
          nil,
          mapToFileProviderError(error, failing: .fetchContents, on: itemIdentifier)
        )
      }
    }
  }

  func createItem(
    basedOn itemTemplate: NSFileProviderItem,
    fields _: NSFileProviderItemFields,
    contents url: URL?,
    options _: NSFileProviderCreateItemOptions = [],
    request _: NSFileProviderRequest,
    completionHandler:
      @escaping @Sendable (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) ->
      Void
  ) -> Progress {
    let name = itemTemplate.filename
    let parent = itemTemplate.parentItemIdentifier
    let contentType = itemTemplate.contentType
    let clientModified = flattened(itemTemplate.contentModificationDate)
    let bornIgnored = DropboxIgnoreMarker.isMarked(itemTemplate.extendedAttributes ?? [:])
    return cancellableTask { [adapterBox] in
      do {
        // An item created already carrying the ignore marker never
        // syncs; it stays local-only from birth.
        guard !bornIgnored else { throw NSFileProviderError(.excludedFromSync) }
        let adapter = try await adapterBox.adapter()
        let item: ProviderItem
        switch contentType {
          case .folder:
            item = try await adapter.createFolder(named: name, in: parent)
          case .symbolicLink:
            // Symlinks cannot be created through the Dropbox API;
            // the system keeps them local and stops asking.
            throw NSFileProviderError(.excludedFromSync)
          default:
            item = try await adapter.createFile(
              named: name,
              in: parent,
              contents: url,
              clientModified: clientModified
            )
        }
        completionHandler(item, [], false, nil)
      } catch {
        // The template carries no identifier yet, so the parent and the
        // requested name are all there is to name the failure by.
        ZephyrLog.provider.error(
          """
          createItem failed for “\(name, privacy: .private)” under \
          \(parent.rawValue, privacy: .private(mask: .hash)): \
          \(String(describing: error), privacy: .private)
          """
        )
        completionHandler(nil, [], false, mapToFileProviderError(error))
      }
    }
  }

  func modifyItem(
    _ item: NSFileProviderItem,
    baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields,
    contents newContents: URL?,
    options _: NSFileProviderModifyItemOptions = [],
    request _: NSFileProviderRequest,
    completionHandler:
      @escaping @Sendable (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) ->
      Void
  ) -> Progress {
    let change = ItemModification(
      item: item,
      baseVersion: version,
      changedFields: changedFields,
      contents: newContents
    )
    return cancellableTask { [adapterBox] in
      do {
        let adapter = try await adapterBox.adapter()
        completionHandler(try await change.apply(with: adapter), [], false, nil)
      } catch {
        completionHandler(
          nil,
          [],
          false,
          mapToFileProviderError(error, failing: .modifyItem, on: change.identifier)
        )
      }
    }
  }

  func deleteItem(
    identifier: NSFileProviderItemIdentifier,
    baseVersion _: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [],
    request _: NSFileProviderRequest,
    completionHandler: @escaping @Sendable ((any Error)?) -> Void
  ) -> Progress {
    let recursive = options.contains(.recursive)
    return cancellableTask { [adapterBox] in
      do {
        try await adapterBox.adapter().delete(identifier, recursive: recursive)
        completionHandler(nil)
      } catch {
        completionHandler(mapToDeletionError(error, failing: .deleteItem, on: identifier))
      }
    }
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier,
    request _: NSFileProviderRequest
  ) throws -> any NSFileProviderEnumerator {
    switch containerItemIdentifier {
      case .workingSet:
        // Narrowing the working set depends on knowing what the system holds
        // on disk, which it only announces when that changes; the first look
        // at the working set is the cue to go and ask.
        Task { [materializedSet] in await materializedSet.scheduleRead() }
        return WorkingSetEnumerator(adapterBox: adapterBox)
      case .trashContainer:
        // Dropbox has no trash; deletes rely on revision history instead.
        ZephyrLog.provider.debug("Refused a trash enumerator: Dropbox has no trash")
        throw NSFileProviderError(.noSuchItem)
      default:
        return ContainerEnumerator(container: containerItemIdentifier, adapterBox: adapterBox)
    }
  }

  /// The system materialized or evicted something; re-read the set so the
  /// working set follows what it now holds on disk.
  func materializedItemsDidChange(completionHandler: @escaping @Sendable () -> Void) {
    Task { [materializedSet] in await materializedSet.scheduleRead() }
    completionHandler()
  }

  private func cancellableTask(_ operation: @escaping @Sendable () async -> Void) -> Progress {
    let task = Task { await operation() }
    let progress = Progress()
    progress.cancellationHandler = { task.cancel() }
    return progress
  }
}

// MARK: Finder context-menu actions

extension FileProviderExtension: NSFileProviderCustomAction {
  func performAction(
    identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
    onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
    completionHandler: @escaping @Sendable ((any Error)?) -> Void
  ) -> Progress {
    guard let action = Action(rawValue: actionIdentifier.rawValue) else {
      completionHandler(NSFileProviderError(.noSuchItem))
      return Progress()
    }
    let domain = self.domain
    return cancellableTask { [adapterBox] in
      do {
        let adapter = try await adapterBox.adapter()
        for identifier in itemIdentifiers {
          switch action {
            case .ignore: _ = try await adapter.ignore(identifier)
            case .resumeSync: _ = try await adapter.resumeSync(identifier)
          }
        }
        // The state change was recorded as a local anchor generation;
        // signaling makes the system come collect it.
        try? await NSFileProviderManager(for: domain)?
          .signalEnumerator(for: .workingSet)
        completionHandler(nil)
      } catch {
        ZephyrLog.provider.error(
          """
          Action \(action.rawValue, privacy: .public) failed: \
          \(String(describing: error), privacy: .private)
          """
        )
        completionHandler(mapToFileProviderError(error))
      }
    }
  }

  /// The action identifiers declared in the extension's Info.plist.
  private enum Action: String {
    case ignore = "codes.tim.Zephyr.ignore"
    case resumeSync = "codes.tim.Zephyr.resumeSync"
  }
}

/// Flattens the doubly-optional value Swift imports an optional Objective-C
/// property of nullable type as, such as `NSFileProviderItem.tagData`.
private func flattened<Value>(_ value: Value??) -> Value? {
  guard let value else { return nil }
  return value
}

/// A `modifyItem` request reduced to Sendable values, applied field group by
/// field group: rename/reparent first (so an accompanying upload lands at the
/// new path), then contents, then system-owned attributes.
struct ItemModification: Sendable {
  let identifier: NSFileProviderItemIdentifier
  let newName: String?
  let newParent: NSFileProviderItemIdentifier?
  let uploadsContents: Bool
  let baseContentVersion: Data?
  let contents: URL?
  let clientModified: Date?
  let tagData: LocalAttributeUpdate<Data>
  let lastUsedDate: LocalAttributeUpdate<Date>
  let extendedAttributes: LocalAttributeUpdate<[String: Data]>

  private var hasAttributeUpdates: Bool {
    if case .set = tagData { return true }
    if case .set = lastUsedDate { return true }
    if case .set = extendedAttributes { return true }
    return false
  }

  init(
    item: NSFileProviderItem,
    baseVersion: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields,
    contents: URL?
  ) {
    identifier = item.itemIdentifier
    newName = changedFields.contains(.filename) ? item.filename : nil
    newParent = changedFields.contains(.parentItemIdentifier) ? item.parentItemIdentifier : nil
    uploadsContents = changedFields.contains(.contents)
    baseContentVersion = baseVersion.contentVersion
    self.contents = contents
    clientModified =
      changedFields.contains(.contentModificationDate)
      ? flattened(item.contentModificationDate) : nil
    tagData = changedFields.contains(.tagData) ? .set(flattened(item.tagData)) : .keep
    lastUsedDate =
      changedFields.contains(.lastUsedDate) ? .set(flattened(item.lastUsedDate)) : .keep
    extendedAttributes =
      changedFields.contains(.extendedAttributes)
      ? .set(item.extendedAttributes ?? [:]) : .keep
  }

  func apply(with adapter: ProviderAdapter) async throws -> ProviderItem {
    var latest: ProviderItem?
    if newName != nil || newParent != nil {
      latest = try await adapter.move(identifier, toParent: newParent, renamedTo: newName)
    }
    if uploadsContents {
      latest = try await adapter.modifyContents(
        of: identifier,
        baseContentVersion: baseContentVersion,
        contents: contents,
        clientModified: clientModified
      )
    }
    if hasAttributeUpdates {
      latest = try await adapter.updateLocalAttributes(
        of: identifier,
        tagData: tagData,
        lastUsedDate: lastUsedDate,
        extendedAttributes: extendedAttributes
      )
    }
    if let latest { return latest }
    // The system sometimes modifies only fields the provider does not
    // track; echoing the current item stops it from retrying forever.
    return try await adapter.item(for: identifier)
  }
}

/// Builds and caches the domain's `ProviderAdapter`, forgetting a failed
/// attempt so the next request retries (a locked keychain at login must not
/// wedge the extension until it is reaped).
actor AdapterBox {
  private let make: @Sendable () async throws -> ProviderAdapter
  private var task: Task<ProviderAdapter, any Error>?

  init(_ make: @escaping @Sendable () async throws -> ProviderAdapter) {
    self.make = make
  }

  func adapter() async throws -> ProviderAdapter {
    // The task's value is awaited in the `do` block below and its error
    // rethrown, which the rule cannot see; the catch also drops the failed
    // task so the next caller retries.
    // swiftlint:disable:next unhandled_throwing_task
    let task = self.task ?? Task { try await make() }
    self.task = task
    do {
      return try await task.value
    } catch {
      if self.task == task { self.task = nil }
      throw error
    }
  }

  func invalidate() {
    task?.cancel()
    task = nil
  }
}
