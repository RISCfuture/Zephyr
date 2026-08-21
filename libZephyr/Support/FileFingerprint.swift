import Foundation

/**
 A snapshot of a file's identity and change-relevant metadata, used to detect
 that a file mutated between two points in time (for example, mid-upload).

 The comparison uses `ctime` because applications cannot forge it, matching
 Maestral's mutation detection.
 */
struct FileFingerprint: Sendable, Equatable {
  /// The file's inode number.
  let inode: UInt64
  /// The file's size in bytes.
  let size: UInt64
  /// The file's last-modification time, in nanoseconds since the epoch.
  let modificationTimeNanoseconds: Int64
  /// The file's last-status-change time, in nanoseconds since the epoch.
  let statusChangeTimeNanoseconds: Int64

  /// Captures the fingerprint of the file at `url` without following symlinks.
  init(of url: URL) throws {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(EINVAL) }
      return lstat(path, &status)
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    inode = UInt64(status.st_ino)
    size = UInt64(clamping: status.st_size)
    modificationTimeNanoseconds = Self.nanoseconds(of: status.st_mtimespec)
    statusChangeTimeNanoseconds = Self.nanoseconds(of: status.st_ctimespec)
  }

  private static func nanoseconds(of time: timespec) -> Int64 {
    Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
  }
}
