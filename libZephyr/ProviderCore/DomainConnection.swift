@preconcurrency public import FileProvider
import Foundation

/**
 Whether Zephyr's registered domains are serving Finder without asking Dropbox
 for anything new — what the menu bar item, the Shortcuts action, and the
 Control Center toggle all call “paused”.

 The app layer owns *which* domains exist: registering one per linked account,
 reconciling them against the account registry, and reaping the ones whose
 account is gone. This owns *whether they are connected*, which is a different
 question and the only one a process outside the app ever asks.

 `NSFileProviderManager` answers it for any executable inside the app bundle
 whose identifier is prefixed by the app's and which shares the provider's
 document group, so the widget extension can pause syncing itself rather than
 waking the app to do it.
 */
public enum DomainConnection {
  /// What Finder tells the user about a domain Zephyr stopped, so a paused
  /// account reads as paused rather than broken.
  private static var pauseReason: String {
    String(localized: "Syncing is paused in Zephyr.", bundle: #bundle)
  }

  /// Stops every registered domain, so Finder reports the account paused
  /// rather than broken while the user has syncing turned off.
  public static func disconnectAll() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      for domain in try await NSFileProviderManager.domains() {
        group.addTask { try await disconnect(domain) }
      }
      try await group.waitForAll()
    }
  }

  /// Stops one registered domain — the domain of an account linked onto a Mac
  /// whose syncing the user had already paused.
  public static func disconnect(_ domain: NSFileProviderDomain) async throws {
    try await NSFileProviderManager(for: domain)?.disconnect(reason: pauseReason)
  }

  /// Starts every registered domain again.
  public static func reconnectAll() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      for domain in try await NSFileProviderManager.domains() {
        group.addTask { try await NSFileProviderManager(for: domain)?.reconnect() }
      }
      try await group.waitForAll()
    }
  }

  /// Whether syncing is paused: every registered domain is disconnected, and
  /// there is at least one.
  public static func areAllDisconnected() async -> Bool {
    guard let domains = try? await NSFileProviderManager.domains(), !domains.isEmpty else {
      return false
    }
    return domains.allSatisfy(\.isDisconnected)
  }

  /**
   Whether the system holds any File Provider domain for Zephyr.

   The difference between syncing that is running and syncing that was never
   set up, which ``areAllDisconnected()`` reports the same way: no domains is
   not paused, but it is not running either.
   */
  public static func hasRegisteredDomains() async -> Bool {
    !((try? await NSFileProviderManager.domains()) ?? []).isEmpty
  }
}
