import Foundation

/**
 The sync summary the app publishes for the widget: one JSON file in the
 shared container, refreshed whenever the app recomputes account statuses.
 */
public struct SyncStatusSnapshot: Sendable, Equatable, Codable {

  /// The widget kind the app reloads after publishing a snapshot.
  public static let widgetKind = "codes.tim.Zephyr.SyncStatusWidget"

  public var accounts: [AccountStatus]
  public var capturedAt: Date

  public init(accounts: [AccountStatus], capturedAt: Date = Date()) {
    self.accounts = accounts
    self.capturedAt = capturedAt
  }

  /// Where the snapshot lives in the shared container.
  public static func fileURL(in environment: ZephyrEnvironment = .standard) -> URL {
    environment.baseDirectory.appending(component: "widget-status.json")
  }

  /// Loads the published snapshot, or `nil` when none exists or it is unreadable.
  public static func load(from environment: ZephyrEnvironment = .standard) -> Self? {
    guard let data = try? Data(contentsOf: fileURL(in: environment)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Self.self, from: data)
  }

  /// Publishes the snapshot atomically.
  public func write(to environment: ZephyrEnvironment = .standard) throws {
    try FileManager.default.createDirectory(
      at: environment.baseDirectory,
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: Self.fileURL(in: environment), options: .atomic)
  }

  /// One account's summary as the widget renders it.
  public struct AccountStatus: Sendable, Equatable, Codable, Identifiable {
    /**
     How many issues one account carries across the app-group boundary.

     The snapshot is a file every widget refresh reads whole, so an account
     whose every item is failing must not turn it into a copy of the index.
     ``syncErrorCount`` still reports the true total.
     */
    public static let maximumCarriedIssues: UInt = 10

    /// The account identifier's raw value.
    public let id: String
    public let displayName: String
    public let files: UInt
    public let folders: UInt
    /**
     How many items couldn't sync, whether or not each one is listed in
     ``syncIssues``.
     */
    public let syncErrorCount: UInt
    /// When the account last saw sync activity.
    public let latestChange: Date?
    /**
     How many items the system is still waiting to push to Dropbox, or `nil`
     where the app hadn't read the pending set when it published.
     */
    public let pendingUploads: UInt?
    /// The newest issues, at most ``maximumCarriedIssues`` of them.
    public let syncIssues: [SyncIssue]
    /**
     What stopped syncing for the whole account, or `nil` while it syncs.

     An account-wide failure is not one of the ``syncErrorCount`` — a revoked
     token is not a file that couldn't sync — so it reads separately.
     */
    public let accountFailure: String?

    /**
     Whether anything about the account wants the user's attention, from a
     single item that couldn't sync up to a failure that stopped it whole.
     */
    public var needsAttention: Bool { accountFailure != nil || syncErrorCount > 0 }

    public init(
      id: String,
      displayName: String,
      files: UInt,
      folders: UInt,
      syncErrorCount: UInt,
      latestChange: Date?,
      pendingUploads: UInt? = nil,
      syncIssues: [SyncIssue] = [],
      accountFailure: String? = nil
    ) {
      self.id = id
      self.displayName = displayName
      self.files = files
      self.folders = folders
      self.syncErrorCount = syncErrorCount
      self.latestChange = latestChange
      self.pendingUploads = pendingUploads
      self.syncIssues = Array(syncIssues.prefix(Int(Self.maximumCarriedIssues)))
      self.accountFailure = accountFailure
    }
  }

  /**
   One item that couldn't sync, reduced to what a reader outside the app can
   render without opening the index.
   */
  public struct SyncIssue: Sendable, Equatable, Codable, Identifiable {
    /// The item's normalized path, unique within an account.
    public let id: String
    /// The item's path as Dropbox spells it.
    public let path: String
    /// What went wrong, in one line.
    public let title: String
    /// Why it went wrong, when the failure said.
    public let detail: String?

    public init(id: String, path: String, title: String, detail: String?) {
      self.id = id
      self.path = path
      self.title = title
      self.detail = detail
    }

    /// Summarizes a recorded failure for readers outside the app's process.
    public init(_ record: SyncErrorRecord) {
      self.init(
        id: record.pathNormalized.rawValue,
        path: record.path.displayPath,
        title: record.title,
        detail: record.detail
      )
    }
  }
}
