import ArgumentParser
import Foundation
import libZephyr

struct BandwidthLimitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bandwidth-limit",
    abstract: "Show or set transfer bandwidth limits.",
    discussion: """
      The limits belong to this Mac rather than to one account: a cap exists because of the link \
      the computer is on, and a link doesn’t know which Dropbox is using it. Every linked \
      account’s transfers share one budget, so these commands take no --account.
      """,
    subcommands: [Up.self, Down.self, Metered.self]
  )

  /// Bytes per megabyte, in the SI sense transfer rates are quoted in.
  fileprivate static let bytesPerMegabyte: Double = 1_000_000

  /// One direction's shared implementation: print when no value is given, set otherwise.
  fileprivate static func showOrSet(
    limitMBps: Double?,
    direction: WritableKeyPath<BandwidthSettings, UInt64> & Sendable,
    label: String
  ) async {
    await CLI.run {
      var settings = BandwidthSettings.load()
      guard let limitMBps else {
        print("\(label): \(describe(settings[keyPath: direction]))")
        return
      }
      settings[keyPath: direction] = try rateBps(limitMBps)
      try settings.save()
      print("\(label): \(describe(settings[keyPath: direction]))")
      print("The new limit takes effect immediately, transfers already running included.")
    }
  }

  fileprivate static func report(_ settings: BandwidthSettings) {
    print("Metered limit: \(describe(settings.meteredLimitBps))")
    print(
      settings.syncsOnExpensiveNetworks
        ? "Indexing on metered networks: yes, except in Low Data Mode"
        : "Indexing on metered networks: no"
    )
  }

  /// A rate in MB/s as bytes per second.
  ///
  /// - Throws: `ValidationError` when the rate is negative.
  fileprivate static func rateBps(_ limitMBps: Double) throws -> UInt64 {
    guard limitMBps >= 0 else { throw ValidationError("The limit can’t be negative.") }
    return UInt64((limitMBps * bytesPerMegabyte).rounded())
  }

  private static func describe(_ bytesPerSecond: UInt64) -> String {
    bytesPerSecond == 0
      ? "unlimited"
      : "\(Output.bytes(bytesPerSecond))/s"
  }

  struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "up",
      abstract: "Show or set the upload bandwidth limit."
    )

    @Argument(help: "The limit in MB/s; 0 removes it. Omit to show the current limit.")
    var limit: Double?

    func run() async {
      await BandwidthLimitCommand.showOrSet(
        limitMBps: limit,
        direction: \.uploadLimitBps,
        label: "Upload limit"
      )
    }
  }

  /// The metered-network limit, plus the standing answer about whether
  /// indexing may run on a network macOS only guesses is expensive.
  struct Metered: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "metered",
      abstract: "Show or set what Zephyr does on a metered network.",
      discussion: """
        A metered network is a personal hotspot, a connection macOS reads as costly, or one in Low \
        Data Mode. The limit caps transfers there; it does not replace the upload and download \
        limits, and whichever is lower applies.

        Indexing and change checks wait for a cheaper network by default. --keep-indexing \
        overrules that for networks macOS only guesses are expensive; Low Data Mode holds them \
        back either way. Files you open download on any network.
        """
    )

    @Argument(help: "The limit in MB/s; 0 removes it. Omit to show the current limit.")
    var limit: Double?

    @Flag(
      inversion: .prefixedNo,
      help: "Whether to keep indexing on networks macOS reads as expensive."
    )
    var keepIndexing: Bool?

    func run() async {
      await CLI.run {
        var settings = BandwidthSettings.load()
        guard limit != nil || keepIndexing != nil else {
          BandwidthLimitCommand.report(settings)
          return
        }
        if let limit { settings.meteredLimitBps = try BandwidthLimitCommand.rateBps(limit) }
        if let keepIndexing { settings.syncsOnExpensiveNetworks = keepIndexing }
        try settings.save()
        BandwidthLimitCommand.report(settings)
        print("The new setting takes effect immediately, transfers already running included.")
      }
    }
  }

  struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "down",
      abstract: "Show or set the download bandwidth limit."
    )

    @Argument(help: "The limit in MB/s; 0 removes it. Omit to show the current limit.")
    var limit: Double?

    func run() async {
      await BandwidthLimitCommand.showOrSet(
        limitMBps: limit,
        direction: \.downloadLimitBps,
        label: "Download limit"
      )
    }
  }
}
