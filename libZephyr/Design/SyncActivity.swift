public import Foundation

/**
 What an account's sync is doing — the reading ``ZephyrMark`` badges itself
 with, and the words the status lines carry.

 The reading covers what this Mac still owes Dropbox: the changes the system
 is waiting to push, which it reports through the File Provider pending set.
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

  /// The one reading the mark's badge and the status lines are drawn from.
  public let state: State

  /// Whether anything the Mac owes Dropbox could actually be sent right now.
  /// Not a state of its own — nothing is said about why — only the difference
  /// between a backlog moving and a backlog sitting still.
  private let canReachDropbox: Bool

  /**
   How many changes are waiting to reach Dropbox, or `nil` where nobody read
   the pending set — a process that has no File Provider manager to ask, or
   the moments before the app's first read.

   A change, not a file: the pending set holds everything this Mac still owes
   Dropbox, so an edit, a rename and a deletion each count once alongside a
   file that has yet to be sent. Nothing here is necessarily an upload.

   The system caps the pending set's own size, so an account with a very
   large backlog reports the cap rather than the true total.
   */
  public let pendingChanges: UInt?

  /// Whether any of the account's items couldn't sync.
  public var hasIssues: Bool { state == .issues }

  /// The state in words, for status lines and for VoiceOver.
  public var summary: String {
    switch state {
      case .paused: String(localized: "Paused", bundle: #bundle)
      case .syncing: syncingSummary
      case .upToDate: String(localized: "Up to date", bundle: #bundle)
      case .issues: String(localized: "Sync issues", bundle: #bundle)
    }
  }

  /**
   What a Mac with outstanding work is doing.

   "Sending" is a claim that bytes are moving, so it is made only where they
   can be: a measured backlog on a path that will carry it. A backlog nothing
   is carrying — held back over what the network costs, or waiting out an
   outage — is still a backlog, and "Syncing" says that much without saying
   more than is true. Why it isn't moving is not answered here; a row of the
   menu-bar panel answers it, and can link to the page about it.
   */
  private var syncingSummary: String {
    guard let pendingChanges, pendingChanges > 0, canReachDropbox else {
      return String(localized: "Syncing", bundle: #bundle)
    }
    return String(localized: "Sending", bundle: #bundle)
  }

  /**
   Reads an account's activity.

   - Parameters:
     - latestChange: When the account's index last recorded a change. It
       decides the reading only where `pendingChanges` is `nil`: the age of a
       change is a guess at activity, and the backlog is a measurement of it.
     - hasIssues: Whether any of the account's items couldn't sync.
     - isPaused: Whether the user has stopped every transfer.
     - canReachDropbox: Whether a backlog could move right now — false while
       the network holds Zephyr back or the Mac is out of touch. It decides
       only whether a backlog reads as sending or merely as outstanding.
     - pendingChanges: How many changes the system is still waiting to push,
       or `nil` where the pending set hasn't been read.
     - now: The moment the reading is taken.
   */
  public init(
    latestChange: Date?,
    hasIssues: Bool,
    isPaused: Bool = false,
    canReachDropbox: Bool = true,
    pendingChanges: UInt? = nil,
    asOf now: Date = Date()
  ) {
    self.pendingChanges = pendingChanges
    self.canReachDropbox = canReachDropbox
    if hasIssues {
      state = .issues
    } else if isPaused {
      state = .paused
    } else if let pendingChanges {
      state = pendingChanges > 0 ? .syncing : .upToDate
    } else if let latestChange, now.timeIntervalSince(latestChange) <= Self.syncingWindowSec {
      state = .syncing
    } else {
      state = .upToDate
    }
  }

  /**
   The four things Zephyr has to say about syncing.

   Only about syncing. What is standing in its way — a network that costs the
   user something, a route that has gone, an approval macOS is withholding —
   is not a reading of how syncing is going, and each of those is now said
   once, in a row of the menu-bar panel that can explain itself and link to
   the page about it. A reading is a word in a status line, and there is no
   word that both names a condition and answers the question a reader of a
   status line is asking.

   Where more than one is true at once the more lasting one wins. Issues
   outlive everything and still want the user, so they keep the reading — a
   file that couldn't sync is still waiting once syncing is resumed. Below
   them a pause outranks the backlog, because none of that backlog is moving
   while it holds.
   */
  public enum State: Sendable, Equatable {
    /// Nothing is moving because the user stopped it. Alone among these, it is
    /// not a reading of anything: nothing was observed, somebody threw a
    /// switch, and it ends when they throw it back.
    case paused
    /// Files are moving: this Mac has changes Dropbox hasn't taken yet.
    case syncing
    /// Nothing this Mac holds is waiting to reach Dropbox.
    case upToDate
    /// Something couldn't sync.
    case issues
  }
}
