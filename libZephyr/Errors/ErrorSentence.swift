import Foundation

/// One failure, in the words a reader sees.
public enum ErrorSentence {
  /**
   Describes a failure as a sentence: the category it belongs to, why it
   happened, and — where the reader can act on it — what to do about it.

   `LocalizedError` splits a failure across three properties on purpose, and
   `localizedDescription` returns only the first of them. A reader told
   “Syncing stopped.” and nothing else has been told the category and not the
   failure, so every surface that shows one of these errors joins the parts
   back together. This is that join.

   `zephyr` does not use this: a terminal wants an unrecognized error spelled
   out as `String(describing:)`, diagnostics and all, where every other
   surface wants the sentence Foundation already has for it.

   - Parameters:
     - error: The failure. One that is not a `LocalizedError` falls back to
       its `localizedDescription`.
     - includingRecovery: Whether to append the recovery suggestion. Somewhere
       with room for it — a shortcut's result, a help page — should; an alert
       already offering the remedy as a button should not.
   - Returns: The failure as one or more sentences, space-separated.
   */
  public static func describe(
    _ error: any Error,
    includingRecovery: Bool = false
  ) -> String {
    let localized = error as? any LocalizedError
    let parts = [
      localized?.errorDescription ?? error.localizedDescription,
      localized?.failureReason,
      includingRecovery ? localized?.recoverySuggestion : nil
    ]
    return parts.compactMap(\.self).joined(separator: " ")
  }
}
