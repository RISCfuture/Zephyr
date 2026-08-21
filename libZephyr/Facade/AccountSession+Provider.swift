import Foundation

extension AccountSession {
  /**
   Creates the File Provider adapter for this account, backed by the
   session's path-rooted client and its sync index opened read-write.

   The extension holding the adapter outlives changes the user makes
   elsewhere, so this also starts watching the account's configuration and the
   transfer pacing: an account moved to a new path root, a bandwidth limit set
   in the app or the CLI, and a Mac put into Low Data Mode all reach transfers
   already running here without waiting for the system to relaunch the
   extension. A write refused because the account's path root moved re-resolves
   the root through this session and retries.

   - Parameter scratchDirectory: Where the adapter stages fetched file
     contents; defaults to the account's cache directory.
   */
  public func makeProviderAdapter(scratchDirectory: URL? = nil) throws -> ProviderAdapter {
    watchConfigurationChanges()
    watchTransferPacing()
    return ProviderAdapter(
      store: try openIndex(mode: .readWrite),
      client: client,
      bulkClient: bulkClient,
      scratchDirectory: scratchDirectory
        ?? environment.cacheDirectory(for: accountID).appending(component: "provider-staging"),
      rootType: configuration.rootType,
      refreshPathRoot: { [self] in try await refreshPathRoot() }
    )
  }
}
