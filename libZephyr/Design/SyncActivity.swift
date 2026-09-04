public import Foundation

/**
 What an account's sync is doing — the reading ``ZephyrMark`` badges itself
 with, and the words the status lines carry.

 The reading covers what this Mac still owes Dropbox: the items the system is
 waiting to push, which it reports through the File Provider pending set.
 Content coming the other way is not in it. A materialization carries its own
 `Progress` inside the File Provider extension and Finder draws it there;
 nothing hands it to the app, so the reading never claims to know whether a
 download is in flight.
 */
public struct SyncActivity: Sendable, Equatable {
  /// The reading for an account that has never reported a change.
  public static let idle = Self(latestChange: nil, hasIssues: false)

  /// How fresh an account's last change has to be for it to still read as
  /// syncing where no backlog was measured — wide enough to span the gap
  /// between two longpoll deliveries, so a run of changes doesn't flicker the
  /// mark.
  private static let syncingWindowSec: TimeInterval = 90

  /// How long an account has to have been out of touch before the wait is
  /// worth naming as trouble. Below it, an outage is a lid that just opened
  /// or a radio still finding its network, and saying so would be alarm.
  private static let prolongedOutageSec: TimeInterval = 5 * 60

  /// The one reading the mark's badge and the status lines are drawn from.
  public let state: State

  /**
   How many items are waiting to reach Dropbox, or `nil` where nobody read
   the pending set — a process that has no File Provider manager to ask, or
   the moments before the app's first read.

   The system caps the pending set's own size, so an account with a very
   large backlog reports the cap rather than the true total.
   */
  public let pendingUploads: UInt?

  /// Whether any of the account's items couldn't sync.
  public var hasIssues: Bool { state == .issues }

  /// The state in words, for status lines and for VoiceOver.
  public var summary: String {
    switch state {
      case .needsSetup: String(localized: "Not set up yet", bundle: #bundle)
      case .syncing: syncingSummary
      case .upToDate: String(localized: "Up to date", bundle: #bundle)
      case .issues: String(localized: "Sync issues", bundle: #bundle)
      case .waitingForCheaperNetwork:
        String(localized: "Waiting for a cheaper network", bundle: #bundle)
      case .offline(let isProlonged):
        isProlonged
          ? String(localized: "Can’t reach Dropbox", bundle: #bundle)
          : String(localized: "Offline", bundle: #bundle)
    }
  }

  /// A measured backlog is named for the one direction it describes; a
  /// reading guessed from the age of a change can only say that much.
  private var syncingSummary: String {
    guard let pendingUploads, pendingUploads > 0 else {
      return String(localized: "Syncing", bundle: #bundle)
    }
    return String(localized: "Uploading", bundle: #bundle)
  }

  /**
   Reads an account's activity.

   - Parameters:
     - latestChange: When the account's index last recorded a change. It
       decides the reading only where `pendingUploads` is `nil`: the age of a
       change is a guess at activity, and the backlog is a measurement of it.
     - hasIssues: Whether any of the account's items couldn't sync.
     - pendingUploads: How many items the system is still waiting to push, or
       `nil` where the pending set hasn't been read.
     - offlineSince: When the account was last able to reach Dropbox, or `nil`
       while it can.
     - isWaitingForCheaperNetwork: Whether syncing is holding back because
       the path costs the user something.
     - canSync: Whether syncing is set up at all — an account is linked and
       macOS is serving the domain. False is a reading in its own right, not
       an absence of one.
     - now: The moment the reading is taken.
   */
  public init(
    latestChange: Date?,
    hasIssues: Bool,
    pendingUploads: UInt? = nil,
    offlineSince: Date? = nil,
    isWaitingForCheaperNetwork: Bool = false,
    canSync: Bool = true,
    asOf now: Date = Date()
  ) {
    self.pendingUploads = pendingUploads
    if hasIssues {
      state = .issues
    } else if !canSync {
      state = .needsSetup
    } else if isWaitingForCheaperNetwork {
      state = .waitingForCheaperNetwork
    } else if let offlineSince {
      state = .offline(isProlonged: now.timeIntervalSince(offlineSince) >= Self.prolongedOutageSec)
    } else if let pendingUploads {
      state = pendingUploads > 0 ? .syncing : .upToDate
    } else if let latestChange, now.timeIntervalSince(latestChange) <= Self.syncingWindowSec {
      state = .syncing
    } else {
      state = .upToDate
    }
  }

  /**
   The six things Zephyr has to say about an account.

   Where more than one is true at once the more lasting one wins: issues
   outlive an outage and still want the user, so they keep the reading, while
   an outage outranks any backlog because none of that backlog is moving. A
   setup that was never finished outlasts both, and so outranks everything
   except the issues that would survive finishing it. A deliberate wait
   outranks an outage for a different reason: both stop the backlog, and only
   one of them can say why.
   */
  public enum State: Sendable, Equatable {
    /// Nothing is set up to sync yet: no account is linked, or macOS is not
    /// serving the domain. Nothing moves until someone finishes the job.
    case needsSetup
    /// Files are moving: this Mac has changes Dropbox hasn't taken yet.
    case syncing
    /// Nothing this Mac holds is waiting to reach Dropbox.
    case upToDate
    /// Something couldn't sync.
    case issues
    /// Nothing is moving on purpose: the path costs the user something, so
    /// the work nobody asked for is holding back until it doesn't. Files the
    /// user opens still download.
    case waitingForCheaperNetwork
    /**
     Nothing can reach Dropbox, and nothing will until a route comes back.

     `isProlonged` once the wait has lasted long enough to be worth naming as
     trouble rather than as the ordinary gap around a sleep.
     */
    case offline(isProlonged: Bool)
  }
}
