import Foundation

/// Something the version-history sheet was asked to show, and could not.
enum FileVersionsFailure: Error, Equatable {
  /// Finder named no file, or more than one.
  case notOneFile

  /// The action arrived without a domain Zephyr recognises, so there is no
  /// account to ask.
  case noAccount

  /// The file Finder named could not be resolved — moved, deleted, or never
  /// indexed since the menu was opened.
  case fileUnavailable
}

extension FileVersionsFailure: LocalizedError {
  var errorDescription: String? {
    String(localized: "Zephyr couldn’t show earlier versions.", bundle: #bundle)
  }

  var failureReason: String? {
    switch self {
      case .notOneFile:
        String(localized: "Versions are shown for one file at a time.", bundle: #bundle)
      case .noAccount:
        // Word for word what `ScriptingFailure.noAccountLinked` says: one
        // condition reads the same however the reader arrived at it.
        String(localized: "No Dropbox account is linked.", bundle: #bundle)
      case .fileUnavailable:
        String(localized: "That file is no longer in your Dropbox.", bundle: #bundle)
    }
  }

  var recoverySuggestion: String? {
    switch self {
      case .notOneFile:
        String(localized: "Select a single file and try again.", bundle: #bundle)
      case .noAccount:
        String(localized: "Open Zephyr and link a Dropbox account.", bundle: #bundle)
      case .fileUnavailable:
        nil
    }
  }
}
