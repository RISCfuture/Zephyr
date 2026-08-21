import ArgumentParser
import Foundation
import libZephyr

/// Shared plumbing for every CLI command: account resolution, error rendering,
/// and exit codes.
enum CLI {
  /// The exit code for "no account linked" (`EX_UNAVAILABLE`), so scripts can
  /// distinguish it and suggest `zephyr auth link`.
  static let notLinkedExitCode: Int32 = 69

  /**
   The version `zephyr --version` reports.

   The tool is a bare executable with no `Info.plist` of its own, so the number
   comes from the framework it links, which the build stamps with the same
   marketing and build versions as every other Zephyr target.
   */
  static let version =
    infoString("CFBundleShortVersionString")
    .map { marketing in
      infoString("CFBundleVersion").map { "\(marketing) (\($0))" } ?? marketing
    } ?? "unknown"

  /// The account manager for the CLI's own token store (the login keychain).
  static func accountManager() -> AccountManager {
    AccountManager(tokenStore: LoginKeychainTokenStore())
  }

  /**
   Resolves the session to operate on: the explicitly requested account, or
   the sole account this tool can authenticate as.

   The app and `zephyr` keep their credentials in different keychains, so an
   account the app has linked is not necessarily one the command line can act
   as. Disambiguating over the accounts whose refresh token the login keychain
   holds keeps the tool from picking one it would then fail to authenticate.
   */
  static func session(account: String?) async throws -> AccountSession {
    let manager = accountManager()
    if let account {
      return try await manager.session(for: try AccountIdentifier(validating: account))
    }
    let usable = try await manager.authenticatableAccounts()
    let soleAccount = usable.first
    guard let soleAccount else { throw EngineFailure.notLinked }
    guard usable.count == 1 else {
      throw ValidationError(
        "Several accounts are linked; pass --account with one of: "
          + (try await choices(among: usable, from: manager))
      )
    }
    return try await manager.session(for: soleAccount)
  }

  /// Runs a command body, rendering failures and exiting with the right code.
  static func run(_ body: () async throws -> Void) async {
    // Every command comes through here, and nothing else does — a shell
    // completion answers without it, which is what keeps the SDK's start-up
    // cost off every press of Tab.
    CrashReporting.start(as: .commandLineTool)

    // Line-buffer stdout so long-running commands stream when piped.
    setvbuf(stdout, nil, _IOLBF, 0)
    do {
      try await body()
    } catch EngineFailure.notLinked {
      printError(
        """
        No Dropbox account is linked for the command line. Run “zephyr auth link” first — the app \
        and “zephyr” keep separate credentials.
        """
      )
      exit(notLinkedExitCode)
    } catch let error as ValidationError {
      printError(error.message)
      exit(ExitCode.validationFailure.rawValue)
    } catch {
      printError(describe(error))
      exit(ExitCode.failure.rawValue)
    }
  }

  /// Formats an error for the terminal: category plus specific reason.
  static func describe(_ error: any Error) -> String {
    guard let localized = error as? any LocalizedError else {
      return String(describing: error)
    }
    return [localized.errorDescription, localized.failureReason, localized.recoverySuggestion]
      .compactMap(\.self)
      .joined(separator: " ")
  }

  /// Writes a line to standard error.
  static func printError(_ message: String) {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
  }

  /**
   Puts an irreversible step to the user, answering `true` when they agree.

   - Parameters:
     - question: What is about to happen, phrased as a question.
     - assumeYes: Whether `--yes` already answered it.
   - Throws: `ValidationError` when there is no terminal to ask on and
     `--yes` did not answer in advance.
   */
  static func confirm(_ question: String, assumeYes: Bool) throws -> Bool {
    guard !assumeYes else { return true }
    guard Output.isInteractive else {
      throw ValidationError("Pass --yes: there is no terminal to confirm on.")
    }
    guard Output.ask("\(question) [y/N]")?.lowercased() == "y" else {
      print("Cancelled.")
      return false
    }
    return true
  }

  /**
   Parses a user-typed Dropbox path leniently: `/`, empty, or missing leading
   slashes all resolve sensibly; trailing slashes are stripped.
   */
  static func dropboxPath(_ string: String) throws -> DropboxPath {
    try DropboxPath(userTyped: string)
  }

  /// Opens a URL in the user's browser, best-effort.
  static func openInBrowser(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try? process.run()
  }

  /// A value from the linked framework's `Info.plist`.
  private static func infoString(_ key: String) -> String? {
    Bundle(for: SyncIndexStore.self).object(forInfoDictionaryKey: key) as? String
  }

  /// The accounts a `--account` message should offer, each with its email.
  private static func choices(
    among accounts: [AccountIdentifier],
    from manager: AccountManager
  ) async throws -> String {
    var described: [String] = []
    for account in accounts {
      described.append(
        "\(account.rawValue) (\(try await manager.configuration(for: account).email))"
      )
    }
    return described.joined(separator: ", ")
  }
}

// MARK: Path completion

extension CLI {
  /// The spelling `--account` takes when its value is joined to it.
  private static let joinedAccountOption = "--account="

  /**
   How long a completion may spend reading the sync index before it answers
   with nothing.

   A completion runs synchronously inside the user's shell on every Tab, so an
   index that is slow to open has to cost a pause rather than the prompt.
   */
  private static let completionDeadline = Duration.milliseconds(750)

  /// How many candidates one Tab offers. Past a screenful the list stops being
  /// a menu, and the shell pays to render every entry of it.
  private static let completionLimit = 200

  /**
   Completes a partially typed Dropbox path from the account's sync index.

   The index holds every item in the account, including ones whose contents
   are not on this Mac, so completion reaches paths that a scan of the file
   system could not see.

   Every failure — no index, no linked account, a database that will not open,
   a path that does not parse — answers with no candidates rather than an
   error, because a completion handler that complains makes the shell it runs
   in unusable.

   - Parameters:
     - typed: The part of the word being completed that precedes the cursor.
     - words: The command line being completed, one element per shell word.
     - kind: Whether the argument can name a file or only a folder.
   - Returns: Candidates spelled as `typed` plus the rest of an item's name,
     so the shell sees each one as an extension of the word already entered.
     Names are matched case-insensitively, the way Dropbox compares paths;
     whether a candidate that differs from `typed` only in case survives is
     then the shell's own case policy to decide.
   */
  static func pathCompletions(
    matching typed: String,
    inCommandLine words: [String],
    offering kind: CompletablePathKind
  ) async -> [String] {
    await completions(givingUpAfter: completionDeadline) {
      let (container, partial) = splitTypedPath(typed)
      guard let account = await completionAccount(inCommandLine: words),
        let folder = try? dropboxPath(container)
      else { return [] }
      return candidates(
        from: await indexedChildren(of: folder, ofAccount: account),
        under: container,
        startingWith: partial,
        offering: kind
      )
    }
  }

  /**
   Runs a completion lookup, answering with nothing when it has not finished
   in time.

   The lookup and the deadline both answer into a stream, and only the first
   answer is read. Nothing waits on the loser: the process prints its
   candidates and exits.
   */
  private static func completions(
    givingUpAfter deadline: Duration,
    from lookup: @escaping @Sendable () async -> [String]
  ) async -> [String] {
    let (answers, answer) = AsyncStream.makeStream(of: [String].self)
    Task { answer.yield(await lookup()) }
    Task {
      try? await Task.sleep(for: deadline)
      answer.yield([])
    }
    for await first in answers { return first }
    return []
  }

  /**
   Splits a partially typed path into the folder to list and the leading
   characters of the name being typed.

   The folder half is kept exactly as the user spelled it — leading slash or
   not — because a candidate the shell will accept has to start with the word
   already on the command line. An empty word is the one exception: with
   nothing to match, completion offers absolute paths.
   */
  private static func splitTypedPath(_ typed: String) -> (container: String, partial: String) {
    guard !typed.isEmpty else { return ("/", "") }
    guard let lastSeparator = typed.lastIndex(of: "/") else { return ("", typed) }
    let afterSeparator = typed.index(after: lastSeparator)
    return (String(typed[...lastSeparator]), String(typed[afterSeparator...]))
  }

  /**
   The account whose index a completion should read: the one named on the
   command line being completed, or the sole linked account.

   With several accounts linked and none named, there is no defensible answer,
   so completion offers nothing — the same position ``CLI/session(account:)``
   takes when it refuses to guess.
   */
  private static func completionAccount(
    inCommandLine words: [String]
  ) async -> AccountIdentifier? {
    if let named = accountArgument(inCommandLine: words) {
      return try? AccountIdentifier(validating: named)
    }
    guard let linked = try? await accountManager().linkedAccounts(), linked.count == 1 else {
      return nil
    }
    return linked.first
  }

  /// The value `--account` carries on a command line, in either spelling.
  private static func accountArgument(inCommandLine words: [String]) -> String? {
    for (position, word) in words.enumerated() {
      if word.hasPrefix(joinedAccountOption) {
        return String(word.dropFirst(joinedAccountOption.count))
      }
      if word == "--account", position + 1 < words.count { return words[position + 1] }
    }
    return nil
  }

  /**
   A folder's entries as the index holds them.

   The index is opened read-only and never migrated, so a completion cannot
   write to a database the app or the File Provider extension is using, and a
   database from a newer build is read rather than upgraded.
   */
  private static func indexedChildren(
    of folder: DropboxPath,
    ofAccount account: AccountIdentifier
  ) async -> [IndexEntryRecord] {
    let url = ZephyrEnvironment.standard.indexURL(for: account)
    guard FileManager.default.fileExists(atPath: url.path),
      let index = try? SyncIndexStore(url: url, mode: .readOnly),
      let children = try? await index.children(of: folder.normalized)
    else { return [] }
    return children
  }

  /// The candidates a folder's entries offer: the container as typed, plus
  /// the entry's own name, plus a slash for a folder so the next Tab carries
  /// on into it.
  private static func candidates(
    from entries: [IndexEntryRecord],
    under container: String,
    startingWith partial: String,
    offering kind: CompletablePathKind
  ) -> [String] {
    let wanted = partial.lowercased()
    let matching = entries.filter { offers($0, startingWith: wanted, as: kind) }
    return matching.prefix(completionLimit).map {
      container + $0.name + ($0.itemType == .folder ? "/" : "")
    }
  }

  /**
   Whether one indexed entry belongs in a completion list.

   An excluded item is left out: excluding it deleted Dropbox's copy, so a
   path argument naming one asks Dropbox about an item it no longer holds.
   “zephyr ignored” is where those are listed.
   */
  private static func offers(
    _ entry: IndexEntryRecord,
    startingWith partial: String,
    as kind: CompletablePathKind
  ) -> Bool {
    guard !entry.ignored else { return false }
    guard kind == .anyItem || entry.itemType == .folder else { return false }
    return entry.name.lowercased().hasPrefix(partial)
  }

  /// What a path argument can name, and so what completing it offers.
  enum CompletablePathKind {
    /// Files and folders alike.
    case anyItem

    /// Folders only, for an argument no file can answer.
    case folder
  }
}

/// Failures that belong to the command line itself rather than to syncing.
enum CLIFailure: LocalizedError {
  case applicationNotInstalled

  var errorDescription: String? { "Couldn’t open the Zephyr app." }

  var failureReason: String? {
    switch self {
      case .applicationNotInstalled: "This Mac has no copy of Zephyr.app registered."
    }
  }

  var recoverySuggestion: String? {
    switch self {
      case .applicationNotInstalled:
        "Move Zephyr.app to your Applications folder and open it once."
    }
  }
}

/**
 A span of time typed on the command line: a whole number and a unit, like
 `90s`, `30m`, `4h`, or `2d`. A bare number counts seconds.
 */
struct CommandDuration: ExpressibleByArgument, Sendable, Equatable, CustomStringConvertible {
  /// One hour, the window a command reaches for when the user names none.
  static let hour = Self(seconds: Unit.hours.seconds)

  /// The span in seconds.
  let seconds: UInt64

  /// The span as a `Duration`.
  var duration: Duration { .seconds(seconds) }

  /// The span in the coarsest unit that divides it evenly, the way a user
  /// would have typed it.
  var description: String {
    let unit = Unit.allCases.last { seconds.isMultiple(of: $0.seconds) } ?? .seconds
    return "\(seconds / unit.seconds)\(unit.rawValue)"
  }

  /// The span in whole minutes, rounded up so anything shorter than a minute
  /// still counts as one.
  var wholeMinutes: UInt64 {
    let minute = Unit.minutes.seconds
    return max(1, (seconds + minute - 1) / minute)
  }

  init?(argument: String) {
    let digits = argument.prefix(while: \.isWholeNumber)
    guard let amount = UInt64(digits), amount > 0,
      let unit = Self.unit(spelled: argument.dropFirst(digits.count))
    else { return nil }
    seconds = amount * unit.seconds
  }

  private init(seconds: UInt64) {
    self.seconds = seconds
  }

  /// The unit a suffix names, defaulting to seconds when there is none.
  private static func unit(spelled suffix: Substring) -> Unit? {
    guard !suffix.isEmpty else { return .seconds }
    guard suffix.count == 1 else { return nil }
    return Unit(rawValue: suffix[suffix.startIndex])
  }

  private enum Unit: Character, CaseIterable {
    case seconds = "s"

    case minutes = "m"

    case hours = "h"

    case days = "d"

    var seconds: UInt64 {
      switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 60 * 60
        case .days: 24 * 60 * 60
      }
    }
  }
}

/**
 A number of bytes typed on the command line: a whole number and an optional
 unit, like `4096`, `500K`, `10M`, or `2G`. Units are powers of 1024, and a
 bare number counts bytes.
 */
struct ByteSize: ExpressibleByArgument, Sendable {
  /// The size in bytes.
  let bytes: UInt64

  init?(argument: String) {
    let digits = argument.prefix(while: \.isWholeNumber)
    guard !digits.isEmpty, let amount = UInt64(digits),
      let unit = Self.unit(spelled: argument.dropFirst(digits.count))
    else { return nil }
    let (scaled, overflowed) = amount.multipliedReportingOverflow(by: unit.bytes)
    guard !overflowed else { return nil }
    bytes = scaled
  }

  /// The unit a suffix names, defaulting to bytes when there is none. The
  /// trailing `B` of `KB` is optional, and case does not matter.
  private static func unit(spelled suffix: Substring) -> Unit? {
    var spelling = suffix.lowercased()
    if spelling.count == 2, spelling.hasSuffix("b") { spelling.removeLast() }
    if spelling == "b" { spelling = "" }
    return Unit(rawValue: spelling)
  }

  private enum Unit: String {
    case bytes = ""

    case kibibytes = "k"

    case mebibytes = "m"

    case gibibytes = "g"

    case tebibytes = "t"

    var bytes: UInt64 {
      switch self {
        case .bytes: 1
        case .kibibytes: 1024
        case .mebibytes: 1024 * 1024
        case .gibibytes: 1024 * 1024 * 1024
        case .tebibytes: 1024 * 1024 * 1024 * 1024
      }
    }
  }
}
