public import FileProvider

// MARK: Items kept downloaded

extension ProviderAdapter {
  /**
   Pins an item to this Mac: its contents download before anything reads
   them, remote updates keep downloading as they arrive, and nothing evicts
   the item to reclaim disk space. Folders pin their whole subtree.

   Nothing is transferred here and no Dropbox call is made. The pin is a row
   in the index that ``ProviderItem/contentPolicy`` reports to the system,
   which schedules the downloads itself.

   Pinning an ignored item first resumes its syncing, since the two states are
   opposites: one asks for the Dropbox copy to be gone, the other for the
   contents to be on this Mac at all times.
   */
  public func keepDownloaded(
    _ identifier: NSFileProviderItemIdentifier
  ) async throws -> ProviderItem {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    guard !entry.keepDownloaded else { return try await freshItem(for: id) }
    if entry.ignored {
      // Puts the contents back on Dropbox before the index stops calling the
      // item ignored, so the two sides never disagree about whether a remote
      // copy exists.
      _ = try await resumeSync(identifier)
    }
    guard let (_, affected) = try await store.setKeepDownloadedState(true, forID: id) else {
      throw NSFileProviderError(.noSuchItem)
    }
    await recordLocalChangeGeneration(updatedIDs: affected)
    return try await freshItem(for: id)
  }

  /**
   Releases an item's pin. The contents stay on this Mac but lose their
   protection: a read downloads them as it would any other item, and the
   system may evict them under disk pressure. Folders release their whole
   subtree.
   */
  public func stopKeepingDownloaded(
    _ identifier: NSFileProviderItemIdentifier
  ) async throws -> ProviderItem {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    guard entry.keepDownloaded else { return try await freshItem(for: id) }
    guard let (_, affected) = try await store.setKeepDownloadedState(false, forID: id) else {
      throw NSFileProviderError(.noSuchItem)
    }
    await recordLocalChangeGeneration(updatedIDs: affected)
    return try await freshItem(for: id)
  }
}
