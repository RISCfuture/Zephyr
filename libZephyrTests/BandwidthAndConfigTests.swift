import Foundation
import Testing

@testable import libZephyr

@Suite
struct `Bandwidth throttle pacing` {
  private let clock = ContinuousClock()

  @Test
  func `an idle throttle passes the first chunk immediately and paces the next`() {
    let now = clock.now
    let first = BandwidthThrottle.reserve(
      byteCount: 1_000_000,
      bytesPerSecond: 1_000_000,
      nextSlot: nil,
      now: now
    )
    #expect(first.start == now)
    #expect(first.next == now + .seconds(1))

    let second = BandwidthThrottle.reserve(
      byteCount: 500_000,
      bytesPerSecond: 1_000_000,
      nextSlot: first.next,
      now: now
    )
    #expect(second.start == now + .seconds(1))
    #expect(second.next == now + .seconds(1.5))
  }

  @Test
  func `a limit of zero paces nothing`() async throws {
    let throttle = BandwidthThrottle(bytesPerSecond: 0)
    #expect(await throttle.isPacing == false)
    let elapsed = try await clock.measure { try await throttle.acquire(10_000_000) }
    #expect(elapsed < .seconds(1))

    await throttle.adoptRate(1_000)
    #expect(await throttle.isPacing)
  }

  @Test
  func `adopting a rate drops the wait the rate it replaced had scheduled`() async throws {
    let throttle = BandwidthThrottle(bytesPerSecond: 1)
    // Four bytes at one byte a second reserves the next four seconds.
    try await throttle.acquire(4)

    await throttle.adoptRate(1_000_000)

    let elapsed = try await clock.measure { try await throttle.acquire(4) }
    #expect(elapsed < .seconds(1))
    #expect(await throttle.bytesPerSecond == 1_000_000)
  }

  /// The cap the network asks for and the limit the user set are separate
  /// dials: whichever is lower decides, and neither erases the other.
  @Test
  func `a ceiling beats an unlimited configured rate`() async {
    let throttle = BandwidthThrottle(bytesPerSecond: 0)
    #expect(await throttle.isPacing == false)

    await throttle.adoptCeiling(1_000)
    #expect(await throttle.bytesPerSecond == 1_000)

    await throttle.adoptCeiling(nil)
    #expect(await throttle.isPacing == false)
  }

  @Test
  func `a configured rate below the ceiling still wins`() async {
    let throttle = BandwidthThrottle(bytesPerSecond: 500, ceiling: 1_000)
    #expect(await throttle.bytesPerSecond == 500)
  }

  /// Leaving Low Data Mode has to restore what the user set, not whatever
  /// rate was last in force under the cap.
  @Test
  func `lifting a ceiling restores the configured rate`() async {
    let throttle = BandwidthThrottle(bytesPerSecond: 5_000, ceiling: 1_000)
    #expect(await throttle.bytesPerSecond == 1_000)

    await throttle.adoptCeiling(nil)
    #expect(await throttle.bytesPerSecond == 5_000)
  }

  @Test
  func `a long idle gap grants no burst credit`() {
    let now = clock.now
    let stale = now - .seconds(60)
    let slot = BandwidthThrottle.reserve(
      byteCount: 4_000_000,
      bytesPerSecond: 1_000_000,
      nextSlot: stale,
      now: now
    )
    #expect(slot.start == now)
    #expect(slot.next == now + .seconds(4))
  }
}

@Suite
struct `Account configuration` {
  // 2026-08-21T00:00:00Z, whole seconds so an ISO 8601 round trip is lossless.
  private static let linkedAt = Date(timeIntervalSince1970: 1_755_734_400)

  private static func account() throws -> AccountIdentifier {
    try AccountIdentifier(validating: "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc")
  }

  private static func decode(_ stored: Data) throws -> AccountConfiguration {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(AccountConfiguration.self, from: stored)
  }

  private static func namespace(_ rawValue: String) throws -> NamespaceIdentifier {
    try NamespaceIdentifier(validating: rawValue)
  }

  @Test
  func `a configuration stored by an earlier build decodes with defaults`() throws {
    let configuration = try Self.decode(
      Data(
        """
        {
          "accountID": "dbid:stored-before-bandwidth-limits",
          "email": "user@example.com",
          "displayName": "User",
          "rootNamespaceID": "1234",
          "linkedAt": "2026-08-21T00:00:00Z",
          "maxParallelUploads": 6,
          "maxParallelDownloads": 6,
          "uploadBandwidthLimit": 500000,
          "downloadBandwidthLimit": 1000000,
          "meteredBandwidthLimit": 250000,
          "syncsOnExpensiveNetworks": true
        }
        """.utf8
      )
    )
    // The bandwidth keys belong to the Mac now, not the account. A file an
    // earlier build wrote still carries them, and decoding has to walk past
    // them rather than fail on an account it would otherwise have to unlink.
    #expect(configuration.email == "user@example.com")
    #expect(configuration.rootType == .personal)
    #expect(configuration.teamHome == nil)
  }

  @Test
  func `a team root round trips and gives way to a personal one`() throws {
    var configuration = AccountConfiguration(
      accountID: try Self.account(),
      email: "franz@acme.com",
      displayName: "Franz Ferdinand",
      root: .team(
        rootNamespaceID: try Self.namespace("7684224"),
        homeNamespaceID: try Self.namespace("3235641"),
        homePath: "/Franz Ferdinand"
      ),
      linkedAt: Self.linkedAt
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let restored = try Self.decode(try encoder.encode(configuration))
    #expect(restored == configuration)
    #expect(restored.rootType == .team)
    #expect(restored.teamHome?.path == "/Franz Ferdinand")
    #expect(restored.teamHome?.namespaceID.rawValue == "3235641")

    let personalRoot = try Self.namespace("3235641")
    configuration.adoptRoot(
      .user(rootNamespaceID: personalRoot, homeNamespaceID: personalRoot)
    )
    #expect(configuration.rootNamespaceID == personalRoot)
    #expect(configuration.rootType == .personal)
    #expect(configuration.teamHome == nil)
  }
}

@Suite
struct `Transfer limits` {
  /// An environment of its own, so a test never reads or writes the limits
  /// this Mac actually syncs at.
  private static func makeEnvironment() throws -> (ZephyrEnvironment, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("zephyr-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (ZephyrEnvironment(baseDirectory: directory), directory)
  }

  @Test
  func `Limits nobody has set read as the defaults`() throws {
    let (environment, directory) = try Self.makeEnvironment()
    defer { try? FileManager.default.removeItem(at: directory) }

    let settings = BandwidthSettings.load(from: environment)
    #expect(settings.uploadLimitBps == 0)
    #expect(settings.downloadLimitBps == 0)
    // Unlike the two directions, an unset metered limit is a real rate rather
    // than unlimited — the one default that is not simply zero.
    #expect(settings.meteredLimitBps == BandwidthSettings.defaultMeteredLimitBps)
    #expect(settings.syncsOnExpensiveNetworks == false)
  }

  @Test
  func `Limits round-trip through the shared container`() throws {
    let (environment, directory) = try Self.makeEnvironment()
    defer { try? FileManager.default.removeItem(at: directory) }

    var settings = BandwidthSettings()
    settings.uploadLimitBps = 500_000
    settings.downloadLimitBps = 2_000_000
    settings.meteredLimitBps = 0
    settings.syncsOnExpensiveNetworks = true
    try settings.save(to: environment)

    let reloaded = BandwidthSettings.load(from: environment)
    #expect(reloaded == settings)
    // A metered limit explicitly set to unlimited has to survive the trip, or
    // it would read back as the default every launch.
    #expect(reloaded.meteredLimitBps == 0)
  }

  @Test
  func `A file an earlier build wrote decodes with defaults for what it lacks`() throws {
    let (environment, directory) = try Self.makeEnvironment()
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data(
      """
      { "uploadBandwidthLimit": 750000 }
      """.utf8
    ).write(to: environment.bandwidthSettingsURL)

    let settings = BandwidthSettings.load(from: environment)
    #expect(settings.uploadLimitBps == 750_000)
    #expect(settings.meteredLimitBps == BandwidthSettings.defaultMeteredLimitBps)
  }

  @Test
  func `Unreadable limits read as the defaults rather than stopping syncing`() throws {
    let (environment, directory) = try Self.makeEnvironment()
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data("not json".utf8).write(to: environment.bandwidthSettingsURL)
    #expect(BandwidthSettings.load(from: environment) == BandwidthSettings())
  }
}
