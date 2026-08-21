import Foundation

/**
 Maps local file-system errors onto the sync error taxonomy, mirroring
 Maestral's `os_to_maestral_error`.

 The status list shows a failure's ``LocalizedError`` text, and a raw
 `POSIXError` or Foundation file error carries none, so a failure has to pass
 through here before it is recorded against an item.
 */
enum OSErrorMapping {
  /// `NSFileErrorMinimum`…`NSFileErrorMaximum`: the block of `NSCocoaErrorDomain`
  /// codes Foundation reserves for file operations.
  private static let cocoaFileErrorCodes = 0...1023

  /// The phrase ``ItemSyncFailure/invalidPath(path:reason:)`` names when the
  /// file system rejected a name for its length.
  private static var nameTooLongReason: String {
    String(localized: "name too long", bundle: #bundle)
  }

  /// The phrase ``ItemSyncFailure/invalidPath(path:reason:)`` names when the
  /// file system rejected the characters in a name.
  private static var invalidCharactersReason: String {
    String(localized: "invalid characters", bundle: #bundle)
  }

  /// The phrase ``ItemSyncFailure/invalidPath(path:reason:)`` names when the
  /// file system refuses a name outright.
  private static var nameNotAllowedReason: String {
    String(localized: "name not allowed", bundle: #bundle)
  }

  /**
   The error restated in Zephyr's taxonomy when it came from the file system,
   and returned unchanged when it did not.

   Use this at the boundary where an arbitrary thrown error is recorded or
   shown: a Dropbox or engine failure already describes itself, while a
   `POSIXError` or a Foundation file error needs naming first.

   - Parameters:
     - error: The error a file operation threw.
     - path: The path the operation touched, for error context.
   */
  static func classified(_ error: any Error, path: String) -> any Error {
    cameFromFileSystem(error) ? itemFailure(for: error, path: path) : error
  }

  /**
   Converts a POSIX errno from a file operation into the matching ``ItemSyncFailure``.

   - Parameters:
     - code: The POSIX error code.
     - path: The local path the operation touched.
   */
  static func itemFailure(for code: POSIXErrorCode, path: String) -> ItemSyncFailure {
    switch code {
      case .EPERM, .EACCES:
        .insufficientPermissions(path: path, detail: nil)
      case .ENOENT:
        .notFound(path: path)
      case .EEXIST:
        .fileConflict(path: path)
      case .EISDIR:
        .isAFolder(path: path)
      case .ENOTDIR:
        .notAFolder(path: path)
      case .ENAMETOOLONG:
        .invalidPath(path: path, reason: nameTooLongReason)
      case .EINVAL:
        .invalidPath(path: path, reason: invalidCharactersReason)
      case .EFBIG:
        .fileSizeExceeded(path: path)
      case .ELOOP:
        .symlink(path: path)
      case .ENOSPC:
        .insufficientSpace(path: path)
      default:
        .fileReadFailed(path: path, detail: readFailureDetail(for: code))
    }
  }

  /// Converts any thrown error from a file operation into the matching ``ItemSyncFailure``.
  static func itemFailure(for error: any Error, path: String) -> ItemSyncFailure {
    let nsError = error as NSError
    if let code = posixCode(in: nsError) {
      return itemFailure(for: code, path: path)
    }
    return cocoaFileFailure(nsError, path: path)
      ?? .fileReadFailed(path: path, detail: nsError.localizedDescription)
  }

  /**
   What to tell the user about an errno the taxonomy does not name outright.

   The conditions a user can act on — a read-only volume, a busy file, a
   network volume that went away — say so in their own words; every other errno
   reports its number, the one detail a support conversation can still use.
   */
  private static func readFailureDetail(for code: POSIXErrorCode) -> String {
    switch code {
      case .EIO:
        String(localized: "The disk reported an input/output error.", bundle: #bundle)
      case .EROFS:
        String(localized: "The volume is read-only.", bundle: #bundle)
      case .EBUSY, .ETXTBSY:
        String(localized: "Another process is using the file.", bundle: #bundle)
      case .EMFILE, .ENFILE:
        String(localized: "Too many files are open.", bundle: #bundle)
      case .EDQUOT:
        String(localized: "The volume’s disk quota is exhausted.", bundle: #bundle)
      case .ESTALE:
        String(localized: "The network volume is no longer available.", bundle: #bundle)
      case .ETIMEDOUT:
        String(localized: "The volume stopped responding.", bundle: #bundle)
      default:
        String(
          localized: "The system reported error \(code.rawValue, format: .number).",
          bundle: #bundle
        )
    }
  }

  /// Whether the error names a file operation, rather than the network, the
  /// Dropbox API, or the engine.
  private static func cameFromFileSystem(_ error: any Error) -> Bool {
    let nsError = error as NSError
    if posixCode(in: nsError) != nil { return true }
    return nsError.domain == NSCocoaErrorDomain && cocoaFileErrorCodes.contains(nsError.code)
  }

  /// The errno the error carries, whether it is the error itself or the
  /// underlying error a Cocoa file API wrapped around it.
  private static func posixCode(in nsError: NSError) -> POSIXErrorCode? {
    if nsError.domain == NSPOSIXErrorDomain {
      return POSIXErrorCode(rawValue: Int32(nsError.code))
    }
    guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
    return posixCode(in: underlying)
  }

  /// The taxonomy case for a `NSCocoaErrorDomain` file error that carries no errno.
  private static func cocoaFileFailure(_ nsError: NSError, path: String) -> ItemSyncFailure? {
    guard nsError.domain == NSCocoaErrorDomain else { return nil }
    switch CocoaError.Code(rawValue: nsError.code) {
      case .fileNoSuchFile, .fileReadNoSuchFile:
        return .notFound(path: path)
      case .fileWriteFileExists:
        return .fileConflict(path: path)
      case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
        return .insufficientPermissions(path: path, detail: nil)
      case .fileWriteOutOfSpace:
        return .insufficientSpace(path: path)
      case .fileWriteInvalidFileName:
        return .invalidPath(path: path, reason: nameNotAllowedReason)
      case .fileReadTooLarge:
        return .fileSizeExceeded(path: path)
      default:
        return nil
    }
  }
}
