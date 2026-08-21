import AppIntents
import Foundation

/**
 Any Zephyr failure, in the one sentence Shortcuts has room for.

 App Intents shows a thrown error's `localizedDescription`, which for a
 `LocalizedError` is `errorDescription` and nothing else — the category, with
 the part naming what actually went wrong dropped. A reader told “Syncing
 stopped.” has been told less than nothing. Conforming to
 `CustomLocalizedStringResourceConvertible` is the supported way to put the
 whole sentence in front of them, and the sentence is the one the app's alerts
 and `zephyr` already show.
 */
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
  private let sentence: String

  /// The failure as Shortcuts shows it.
  ///
  /// A literal rather than an interpolation: the sentence has already been
  /// translated, and interpolating it would put a bare `%@` in the catalog
  /// and ask translators to translate a placeholder.
  var localizedStringResource: LocalizedStringResource {
    LocalizedStringResource(stringLiteral: sentence)
  }

  /// Wraps a failure in the sentence a shortcut shows for it.
  init(_ error: any Error) {
    sentence = ErrorSentence.describe(error, includingRecovery: true)
  }
}

/**
 Runs an intent's work, reporting whatever fails in words.

 Two kinds of error go through untouched. `CancellationError`, because
 Shortcuts handles a cancelled action itself and dressing one up as a failure
 would report a stopped shortcut as a broken one. And `AppIntentError`,
 because that is how an intent asks Shortcuts for something — the missing
 value behind `needsValueError(_:)` is a prompt, and wrapping it would turn
 the question into a complaint.

 - Parameter work: The fallible part of a `perform()`.
 - Returns: Whatever `work` returned.
 - Throws: `IntentFailure`, or the two above unchanged.
 */
public func withIntentFailures<Result>(
  _ work: () async throws -> Result
) async throws -> Result {
  do {
    return try await work()
  } catch let error as CancellationError {
    throw error
  } catch let error as AppIntentError {
    throw error
  } catch {
    throw IntentFailure(error)
  }
}
