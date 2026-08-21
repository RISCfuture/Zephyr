import AppKit
import AuthenticationServices
import libZephyr

/**
 Dropbox's authorization page, run from inside the app.

 `ASWebAuthenticationSession` shows the page in a browser Zephyr doesn't own and
 hands back the URL that page finally redirects to. Two things follow from that.
 The browser's own cookies are in play, so someone already signed in to
 dropbox.com approves without retyping anything — which is why
 `prefersEphemeralWebBrowserSession` is left off. And the password is typed into
 another process's window, so Zephyr never sees it.

 The session is a one-shot object with a completion handler, wrapped here in an
 `async` call. It is held in a property for the length of the round trip: a
 session nothing retains tears itself down before the user can answer.

 That handler is `@Sendable` because macOS promises it no particular queue. A
 session that ends before the page ever loads — the user refusing the consent
 alert, say — reports that from the XPC reply queue it heard the refusal on.
 `ASWebAuthenticationSessionCompletionHandler` is an unannotated Objective-C
 block, so a handler written without `@Sendable` infers this class's main-actor
 isolation instead, and traps on the isolation check the compiler inserts for
 an Objective-C caller. Hence the hop: the handler is isolated to nothing and
 reaches ``finish(with:)`` through the main actor.
 */
@MainActor
final class WebAuthSession: NSObject {

  /// The session in flight, held so it outlives the call that started it.
  private var session: ASWebAuthenticationSession?

  /// Whoever is waiting on that session, held so the round trip can be ended
  /// from either side: the page answering, or the caller giving up on it.
  private var continuation: CheckedContinuation<URL, any Error>?

  /// What the completion handler reports, as a result to resume the caller with.
  nonisolated private static func outcome(callbackURL: URL?, error: (any Error)?) -> Result<
    URL, any Error
  > {
    if let callbackURL { return .success(callbackURL) }
    guard let error else { return .failure(Failure.noCallback) }
    guard let sessionError = error as? ASWebAuthenticationSessionError,
      sessionError.code == .canceledLogin
    else { return .failure(error) }
    return .failure(CancellationError())
  }

  /**
   Shows `url` in a web authentication session and returns the callback URL it
   ends on.

   - Parameter callbackScheme: The URL scheme the page redirects to when it is
     done, which is what tells the session the round trip has finished. The app
     has to declare it in `CFBundleURLTypes` as well.
   - Returns: The callback URL, carrying either an authorization code or
     Dropbox's reason for refusing.
   - Throws: `CancellationError` when the user closes the page without
     answering, ``Failure`` when the session couldn't run at all, and whatever
     `ASWebAuthenticationSession` reports otherwise.
   */
  func authorize(url: URL, callbackScheme: String) async throws -> URL {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        let session = ASWebAuthenticationSession(
          url: url,
          callback: .customScheme(callbackScheme)
        ) { @Sendable [weak self] callbackURL, error in
          let outcome = Self.outcome(callbackURL: callbackURL, error: error)
          Task { @MainActor in self?.finish(with: outcome) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        guard session.start() else {
          finish(with: .failure(Failure.couldNotStart))
          return
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }

  /**
   Takes the page down and reports that as a cancellation.

   Both halves are this method's to do. `ASWebAuthenticationSession.cancel()`
   dismisses the window without calling the completion handler, so a caller
   that gave up waiting would otherwise go on waiting forever.
   */
  private func cancel() {
    session?.cancel()
    finish(with: .failure(CancellationError()))
  }

  /// Resumes whoever is waiting, once, and lets go of the session that was
  /// running for them.
  private func finish(with outcome: Result<URL, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    session = nil
    continuation.resume(with: outcome)
  }

  /// Why the authorization page never got as far as asking the user anything.
  enum Failure: Error, LocalizedError {
    /// macOS refused to open the page.
    case couldNotStart
    /// The page closed reporting neither a callback nor a reason.
    case noCallback

    var errorDescription: String? {
      String(localized: "Couldn’t open Dropbox’s authorization page.", bundle: #bundle)
    }

    var failureReason: String? {
      switch self {
        case .couldNotStart:
          String(localized: "macOS wouldn’t open it.", bundle: #bundle)
        case .noCallback:
          String(localized: "It closed without answering.", bundle: #bundle)
      }
    }

    var recoverySuggestion: String? {
      String(
        localized: "Try again, or link the account with an authorization code instead.",
        bundle: #bundle
      )
    }

    var helpAnchor: String? { HelpAnchor.linkAccount.rawValue }
  }
}

extension WebAuthSession: ASWebAuthenticationPresentationContextProviding {
  /**
   The window to hang the authorization page off: whichever of Zephyr's is in
   front.

   The link form is either in a sheet over the accounts window or on a page of
   the setup window, and both are key while the button that leads here is being
   pressed. The last resort is an empty window, because the anchor isn't
   optional — a session presented from one is still a session the user can
   answer, which is better than not offering the page at all.
   */
  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
      ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
  }
}
