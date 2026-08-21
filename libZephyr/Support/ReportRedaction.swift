import Foundation
import Sentry

/**
 Strips out of a crash report everything Zephyr has promised not to send.

 Zephyr's errors are built to name the item that failed — every
 ``ItemSyncFailure`` case carries a Dropbox path — and a crash reason, an
 exception message, or a breadcrumb built from one would carry that path to
 Sentry along with it. The privacy policy says plainly that no file name,
 folder name, path, or credential leaves the Mac, and this is the last thing
 standing between such a string and the network. Both of ``CrashReporting``'s
 outbound hooks run through here.

 It errs toward redacting. A path is taken to run to the end of its line,
 because a Dropbox name may contain spaces and nothing in the surrounding text
 says where one stops — so a message that mentions a path early loses the rest
 of its sentence. That is the intended trade: an issue is grouped and triaged
 by exception type and stack trace, and neither of those is touched.
 */
enum ReportRedaction {
  /// What every redacted run is replaced with. Distinctive on purpose, so that
  /// a message in Sentry that reads oddly can be searched for.
  static let placeholder = "⟨redacted⟩"

  // Each of these is a compiled pattern and nothing else — immutable once the
  // literal is parsed, with no state for a second thread to race on. `Regex`
  // simply does not say so itself.

  /// A `file:` URL. Matched before ``path`` because that rule cannot see one:
  /// every slash in `file:///…` follows the scheme's own, which is exactly
  /// the shape the rule refuses to match so that an `https:` URL survives.
  nonisolated(unsafe) private static let fileURL = #/file:/\S*/#

  /// An email address, which is how a Dropbox account names its owner.
  nonisolated(unsafe) private static let email =
    #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#

  /// A Dropbox short-lived access token. Nothing captured here should ever
  /// hold one; it costs a regex to be sure.
  nonisolated(unsafe) private static let token = #/sl\.[A-Za-z0-9_\-]{20,}/#

  /**
   An absolute or home-relative path, and the rest of the line it sits on.

   The leading group is what keeps the rule out of `https://host/route`: a
   slash that follows a colon, another slash, or a word character belongs to a
   URL rather than to a path, and so does not open a match. It also spares
   `and/or`, `N/A`, and `1/2`. Whatever it consumed is put back, so only the
   path itself is replaced.
   */
  nonisolated(unsafe) private static let path = #/(?<lead>^|[^:/\w~])(?:~?/[^\s/][^\n]*)/#

  /**
   A path written for a person rather than for a filesystem, as
   ``DropboxPath/breadcrumb`` writes one: its components divided by chevrons
   instead of run together on slashes, which ``path`` is anchored to and so
   cannot see.

   The whole line goes, not just the path. A component may hold spaces, so
   there is no boundary that reliably says where the first one began -- and a
   report that loses a sentence is a smaller cost than one that keeps a folder
   name. Nothing else Zephyr reports carries a chevron, so nothing else is
   caught by it.
   */
  nonisolated(unsafe) private static let breadcrumbPath = #/[^\n]* \u{203A} [^\n]*/#

  /// The event Sentry may send. Redaction never discards one: a crash whose
  /// message is gone is still the crash.
  static func redacting(_ event: Event) -> Event {
    event.message = event.message.map(redacting)
    event.exceptions = event.exceptions?.map(redacting)
    event.breadcrumbs = event.breadcrumbs?.map(redacting)
    event.extra = event.extra.map(redacted(_:))
    event.request?.url = event.request?.url.map(redacted(_:))
    return event
  }

  /// The breadcrumb Sentry may keep against a later event.
  static func redacting(_ breadcrumb: Breadcrumb) -> Breadcrumb {
    breadcrumb.message = breadcrumb.message.map(redacted(_:))
    for (key, value) in breadcrumb.data ?? [:] {
      breadcrumb.setData(value: redactedValue(value), key: key)
    }
    return breadcrumb
  }

  /// The string with every path, address, and token in it replaced.
  static func redacted(_ string: String) -> String {
    var redacted = string.replacing(fileURL, with: placeholder)
    redacted = redacted.replacing(email, with: placeholder)
    redacted = redacted.replacing(token, with: placeholder)
    redacted = redacted.replacing(path) { "\($0.lead)\(placeholder)" }
    return redacted.replacing(breadcrumbPath, with: placeholder)
  }

  /// The dictionary with every string anywhere inside it redacted.
  static func redacted(_ values: [String: Any]) -> [String: Any] {
    values.mapValues(redactedValue)
  }

  /**
   A `SentryMessage` whose text is redacted.

   Rebuilt rather than edited: `formatted` is what Sentry serializes and what
   the issue's title is drawn from, and it is fixed at initialization.
   */
  private static func redacting(_ message: SentryMessage) -> SentryMessage {
    let redacted = SentryMessage(formatted: self.redacted(message.formatted))
    redacted.message = message.message.map(self.redacted(_:))
    redacted.params = message.params?.map(self.redacted(_:))
    return redacted
  }

  /// The exception with its message redacted. Its type, module, and stack
  /// trace are left alone: they name Zephyr's own code, not the user's.
  private static func redacting(_ exception: Exception) -> Exception {
    exception.value = exception.value.map(redacted(_:))
    return exception
  }

  /// One value out of a breadcrumb's or an event's free-form dictionary,
  /// redacted however deeply it nests.
  private static func redactedValue(_ value: Any) -> Any {
    switch value {
      case let string as String: redacted(string)
      case let values as [String: Any]: redacted(values)
      case let values as [Any]: values.map(redactedValue)
      default: value
    }
  }
}
