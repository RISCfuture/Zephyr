import Foundation
import os

/**
 Uploads local files to Dropbox: single-shot for small files, chunked upload
 sessions for large ones, with per-chunk content-hash verification and
 corruption retries, mid-upload mutation detection, and offset recovery —
 Maestral's upload semantics.

 ## Resuming across processes

 Given an index to checkpoint into, a chunked upload also survives the death
 of the process running it, which Maestral does not attempt. After every
 acknowledged chunk the uploader records the session, the byte count Dropbox
 has committed, and the content hash of exactly those bytes. A later attempt
 at the same destination continues that session only when Dropbox still
 agrees on the offset and the file's committed prefix still hashes to what
 was sent; every other outcome opens a fresh session, which is always correct
 and costs no more than the bytes already transferred.
 */
struct FileUploader: Sendable {
  /// Files larger than this use an upload session; also the session chunk
  /// size, and the block size the Dropbox content hash is defined over.
  private static let chunkSize = 4 * 1024 * 1024

  /// How much of a file is read at a time when re-hashing a committed prefix.
  private static let prefixReadSize = 65536

  /// Decides how corruption-classed failures retry.
  private static let policy = RetryPolicy()

  /// How many server-reported offset mismatches may be recovered before giving up.
  private static let maximumOffsetRecoveries: UInt = 10

  private let client: DropboxClient

  /// Where in-flight sessions are checkpointed, when the caller has an index
  /// to keep them in. Without one, an interrupted upload simply starts over.
  private let checkpoints: SyncIndexStore?

  init(client: DropboxClient, checkpointingInto checkpoints: SyncIndexStore? = nil) {
    self.client = client
    self.checkpoints = checkpoints
  }

  private static func chunkHash(_ chunk: Data) -> ContentHash {
    var hasher = DropboxContentHasher()
    hasher.update(chunk)
    return hasher.finalize()
  }

  /// The content hash of everything a hasher has consumed, leaving the hasher
  /// able to consume more.
  private static func hash(of hasher: DropboxContentHasher) -> ContentHash {
    let snapshot = hasher
    return snapshot.finalize()
  }

  /**
   Uploads the file at `localURL` to `path`.

   - Parameters:
     - mode: The commit mode; ``WriteMode/update(_:)`` with the last-known
       revision is the lost-update guard.
     - autorename: Whether the server resolves conflicts by renaming
       (producing conflicted copies for stale ``WriteMode/update(_:)``).
     - clientModified: The modification date to commit; defaults to the
       local file's.
   - Throws: ``ItemSyncFailure/dataChanged(path:)`` when the file mutates
     mid-upload; the caller retries on the next change event.
   */
  func upload(
    _ localURL: URL,
    to path: DropboxPath,
    mode: WriteMode,
    autorename: Bool = true,
    clientModified: Date? = nil
  ) async throws -> FileMetadata {
    let fingerprint = try FileFingerprint(of: localURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
    let size = (attributes[.size] as? UInt64) ?? 0
    let clientModified =
      clientModified
      ?? (attributes[.modificationDate] as? Date) ?? Date()
    let commit = UploadCommitInfo(
      path: path,
      mode: mode,
      autorename: autorename,
      clientModified: clientModified
    )

    do {
      if size <= UInt64(Self.chunkSize) {
        ZephyrLog.signposter.emitEvent(
          "Upload",
          "bytes: \(size, privacy: .public), session: false"
        )
        return try await uploadSingleShot(localURL, commit: commit, fingerprint: fingerprint)
      }
      ZephyrLog.signposter.emitEvent("Upload", "bytes: \(size, privacy: .public), session: true")
      return try await uploadInSession(
        localURL,
        size: size,
        commit: commit,
        fingerprint: fingerprint
      )
    } catch is IncorrectOffsetSignal {
      // The internal transport signal must never escape the uploader.
      throw ItemSyncFailure.dataCorruption(path: commit.path)
    }
  }

  private func uploadSingleShot(
    _ localURL: URL,
    commit: UploadCommitInfo,
    fingerprint: FileFingerprint
  ) async throws -> FileMetadata {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval("Upload single-shot", id: signposter.makeSignpostID())
    var bytes = 0
    defer {
      signposter.endInterval("Upload single-shot", state, "bytes: \(bytes, privacy: .public)")
    }
    let body = try Data(contentsOf: localURL)
    bytes = body.count
    try ensureUnchanged(localURL, since: fingerprint, path: commit.path)
    let contentHash = Self.chunkHash(body)
    return try await withCorruptionRetries {
      try await client.uploadSmall(commit: commit, contentHash: contentHash, body: body)
    }
  }

  private func uploadInSession(
    _ localURL: URL,
    size: UInt64,
    commit: UploadCommitInfo,
    fingerprint: FileFingerprint
  ) async throws -> FileMetadata {
    let handle = try FileHandle(forReadingFrom: localURL)
    defer { try? handle.close() }

    var progress: SessionProgress
    if let resumed = try await resumedSession(for: commit, handle: handle, size: size) {
      progress = resumed
    } else {
      progress = try await startedSession(
        for: commit,
        handle: handle,
        localURL: localURL,
        fingerprint: fingerprint
      )
    }

    do {
      let metadata = try await appendAndFinish(
        progress: &progress,
        from: handle,
        size: size,
        localURL: localURL,
        fingerprint: fingerprint,
        commit: commit
      )
      await discardCheckpoint(for: commit)
      return metadata
    } catch let failure as ItemSyncFailure {
      if case .dataChanged = failure {
        // Close the abandoned session so the server can reclaim it early;
        // its bytes no longer describe any file worth resuming.
        try? await client.uploadSessionAppend(
          session: progress.session,
          offset: progress.offset,
          body: Data(),
          contentHash: nil,
          close: true
        )
        await discardCheckpoint(for: commit)
      }
      throw failure
    }
  }

  /// Opens a session with the file's first chunk and checkpoints it.
  private func startedSession(
    for commit: UploadCommitInfo,
    handle: FileHandle,
    localURL: URL,
    fingerprint: FileFingerprint
  ) async throws -> SessionProgress {
    try handle.seek(toOffset: 0)
    var offset: UInt64 = 0
    let firstChunk = try readChunk(
      from: handle,
      at: &offset,
      localURL: localURL,
      fingerprint: fingerprint,
      path: commit.path
    )
    // The session's first chunk rides along with the call that opens it, so
    // without its own interval the opening megabytes of every session upload
    // are the one stretch of the transfer a trace cannot see.
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(
      "Upload session start",
      id: signposter.makeSignpostID(),
      "bytes: \(firstChunk.count, privacy: .public)"
    )
    let session: UploadSessionIdentifier
    do {
      defer { signposter.endInterval("Upload session start", state) }
      session = try await withCorruptionRetries {
        try await client.uploadSessionStart(
          body: firstChunk,
          contentHash: Self.chunkHash(firstChunk)
        )
      }
    }
    var prefix = DropboxContentHasher()
    prefix.update(firstChunk)
    let progress = SessionProgress(
      session: session,
      startedAt: Date(),
      offset: offset,
      prefix: prefix
    )
    await checkpoint(progress, for: commit)
    return progress
  }

  /**
   The session an earlier process left behind, positioned and verified so it
   can simply be continued, or `nil` when there is nothing safe to resume.

   Three things must hold, and each is checked against something other than
   the checkpoint's own word: Dropbox must still know the session, it must
   have committed exactly the number of bytes recorded, and the file's first
   that-many bytes must still hash to what was uploaded. Dropbox is asked
   first because that costs a request with no body, where the hash costs
   reading the whole committed prefix.
   */
  private func resumedSession(
    for commit: UploadCommitInfo,
    handle: FileHandle,
    size: UInt64
  ) async throws -> SessionProgress? {
    guard let checkpoints,
      let recorded = try? await checkpoints.resumableUploadSession(
        forPath: commit.normalizedPath
      ),
      recorded.committedOffset <= size,
      await sessionStandsAt(recorded)
    else { return nil }
    guard let prefix = try prefixHasher(of: handle, length: recorded.committedOffset),
      Self.hash(of: prefix) == recorded.prefixHash
    else {
      ZephyrLog.transfers.info("The file changed since its upload session; starting over.")
      await discardCheckpoint(for: commit)
      return nil
    }
    try handle.seek(toOffset: recorded.committedOffset)
    ZephyrLog.transfers.info(
      "Resuming an upload session at \(recorded.committedOffset, privacy: .public) bytes."
    )
    return SessionProgress(
      session: recorded.sessionID,
      startedAt: recorded.startedAt,
      offset: recorded.committedOffset,
      prefix: prefix
    )
  }

  /**
   Whether Dropbox still holds the session and has committed exactly the
   bytes the checkpoint claims, asked by appending nothing at that offset.

   Any answer other than a plain acknowledgement means the session cannot be
   resumed — it expired, it was closed, it sits at an offset whose extra
   bytes nothing can vouch for, or Dropbox declined to answer the probe at
   all. A fresh session is correct in every one of those cases, so no failure
   here is worth raising to the caller.
   */
  private func sessionStandsAt(_ recorded: UploadSessionRecord) async -> Bool {
    do {
      try await client.uploadSessionAppend(
        session: recorded.sessionID,
        offset: recorded.committedOffset,
        body: Data(),
        contentHash: nil
      )
      return true
    } catch {
      ZephyrLog.transfers.info(
        """
        An upload session can no longer be resumed; starting over: \
        \(error.localizedDescription, privacy: .private)
        """
      )
      return false
    }
  }

  /**
   Sends the rest of the file, then commits it.

   The two phases share one budget of offset recoveries: a session that keeps
   being told it sits somewhere else is one to give up on, wherever in the
   file that happens.
   */
  private func appendAndFinish(
    progress: inout SessionProgress,
    from handle: FileHandle,
    size: UInt64,
    localURL: URL,
    fingerprint: FileFingerprint,
    commit: UploadCommitInfo
  ) async throws -> FileMetadata {
    var offsetRecoveries: UInt = 0
    try await appendWholeChunks(
      progress: &progress,
      recoveries: &offsetRecoveries,
      from: handle,
      size: size,
      localURL: localURL,
      fingerprint: fingerprint,
      commit: commit
    )
    return try await finishSession(
      progress: &progress,
      recoveries: &offsetRecoveries,
      from: handle,
      localURL: localURL,
      fingerprint: fingerprint,
      commit: commit
    )
  }

  /// Appends whole chunks until what is left fits in the commit, checkpointing
  /// each one Dropbox acknowledges.
  private func appendWholeChunks(
    progress: inout SessionProgress,
    recoveries: inout UInt,
    from handle: FileHandle,
    size: UInt64,
    localURL: URL,
    fingerprint: FileFingerprint,
    commit: UploadCommitInfo
  ) async throws {
    while size > progress.offset, size - progress.offset > UInt64(Self.chunkSize) {
      let chunkOffset = progress.offset
      let chunk = try readChunk(
        from: handle,
        at: &progress.offset,
        localURL: localURL,
        fingerprint: fingerprint,
        path: commit.path
      )
      let chunkHash = Self.chunkHash(chunk)
      do {
        // Scoped to the send alone: the checkpoint that follows is a local
        // write, and folding it in would bill it to the network.
        do {
          let signposter = ZephyrLog.signposter
          let state = signposter.beginInterval(
            "Upload chunk",
            id: signposter.makeSignpostID(),
            "offset: \(chunkOffset, privacy: .public), bytes: \(chunk.count, privacy: .public)"
          )
          defer { signposter.endInterval("Upload chunk", state) }
          try await withCorruptionRetries {
            try await client.uploadSessionAppend(
              session: progress.session,
              offset: chunkOffset,
              body: chunk,
              contentHash: chunkHash
            )
          }
        }
        progress.prefix?.update(chunk)
        await checkpoint(progress, for: commit)
      } catch let signal as IncorrectOffsetSignal {
        try await recover(
          from: signal,
          handle: handle,
          progress: &progress,
          recoveries: &recoveries,
          commit: commit
        )
      }
    }
  }

  /// Commits the session with whatever is left of the file, retrying from the
  /// server's own offset for as long as it keeps reporting a different one.
  private func finishSession(
    progress: inout SessionProgress,
    recoveries: inout UInt,
    from handle: FileHandle,
    localURL: URL,
    fingerprint: FileFingerprint,
    commit: UploadCommitInfo
  ) async throws -> FileMetadata {
    while true {
      let finishOffset = progress.offset
      var readOffset = progress.offset
      let finalChunk = try readChunk(
        from: handle,
        at: &readOffset,
        localURL: localURL,
        fingerprint: fingerprint,
        path: commit.path
      )
      let finalChunkHash = finalChunk.isEmpty ? nil : Self.chunkHash(finalChunk)
      do {
        let signposter = ZephyrLog.signposter
        let state = signposter.beginInterval(
          "Upload finish",
          id: signposter.makeSignpostID(),
          "offset: \(finishOffset, privacy: .public), bytes: \(finalChunk.count, privacy: .public)"
        )
        defer { signposter.endInterval("Upload finish", state) }
        return try await withCorruptionRetries {
          try await client.uploadSessionFinish(
            session: progress.session,
            offset: finishOffset,
            commit: commit,
            body: finalChunk,
            contentHash: finalChunkHash
          )
        }
      } catch let signal as IncorrectOffsetSignal {
        try await recover(
          from: signal,
          handle: handle,
          progress: &progress,
          recoveries: &recoveries,
          commit: commit
        )
      }
    }
  }

  /**
   Seeks to the server's reported offset so the next read resends from there.

   The checkpoint goes with it: the running prefix hash describes the bytes
   this uploader believed it had sent, which the server has just contradicted,
   and a checkpoint nothing can prove is worse than none.
   */
  private func recover(
    from signal: IncorrectOffsetSignal,
    handle: FileHandle,
    progress: inout SessionProgress,
    recoveries: inout UInt,
    commit: UploadCommitInfo
  ) async throws {
    guard recoveries < Self.maximumOffsetRecoveries else {
      throw ItemSyncFailure.dataCorruption(path: commit.path)
    }
    recoveries += 1
    try handle.seek(toOffset: signal.correctOffset)
    progress.offset = signal.correctOffset
    progress.prefix = nil
    await discardCheckpoint(for: commit)
  }

  /**
   Records what Dropbox has acknowledged, so another process can pick the
   session up.

   Called only after an append returns, which is what keeps the recorded
   offset from ever claiming more than the server holds. A checkpoint that
   cannot be written costs a resume, never an upload, so failing to write one
   is logged rather than raised.
   */
  private func checkpoint(_ progress: SessionProgress, for commit: UploadCommitInfo) async {
    guard let checkpoints, let prefix = progress.prefix else { return }
    do {
      try await checkpoints.recordUploadSession(
        UploadSessionRecord(
          pathNormalized: commit.normalizedPath,
          sessionID: progress.session,
          committedOffset: progress.offset,
          prefixHash: Self.hash(of: prefix),
          startedAt: progress.startedAt
        )
      )
    } catch {
      ZephyrLog.transfers.debug(
        "Couldn’t checkpoint an upload session: \(error.localizedDescription, privacy: .private)"
      )
    }
  }

  private func discardCheckpoint(for commit: UploadCommitInfo) async {
    try? await checkpoints?.clearUploadSession(forPath: commit.normalizedPath)
  }

  /// A hasher fed the file's first `length` bytes, or `nil` when the file no
  /// longer holds that many — a file that shrank cannot be resumed.
  private func prefixHasher(
    of handle: FileHandle,
    length: UInt64
  ) throws -> DropboxContentHasher? {
    try handle.seek(toOffset: 0)
    var hasher = DropboxContentHasher()
    var remaining = length
    while remaining > 0 {
      let wanted = Int(min(remaining, UInt64(Self.prefixReadSize)))
      guard let piece = try handle.read(upToCount: wanted), piece.count == wanted else {
        return nil
      }
      hasher.update(piece)
      remaining -= UInt64(piece.count)
    }
    return hasher
  }

  /// Retries corruption-classed failures per policy; the request bodies live
  /// in memory, so a retry simply resends the same bytes.
  private func withCorruptionRetries<Result: Sendable>(
    _ body: () async throws -> Result
  ) async throws -> Result {
    var attempt: UInt = 0
    var generator = SystemRandomNumberGenerator()
    while true {
      do {
        return try await body()
      } catch let failure as ItemSyncFailure {
        guard case .dataCorruption = failure else { throw failure }
        switch Self.policy.decision(for: .dataCorruption, attempt: attempt, using: &generator) {
          case .retry(let delay):
            try await ContinuousClock().sleep(for: delay)
            attempt += 1
          case .giveUp:
            throw failure
        }
      }
    }
  }

  /// Reads the next chunk, then verifies the file did not change while (or
  /// before) it was read — the post-read check is what catches torn reads.
  private func readChunk(
    from handle: FileHandle,
    at offset: inout UInt64,
    localURL: URL,
    fingerprint: FileFingerprint,
    path: String
  ) throws -> Data {
    let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
    try ensureUnchanged(localURL, since: fingerprint, path: path)
    offset += UInt64(chunk.count)
    return chunk
  }

  private func ensureUnchanged(
    _ localURL: URL,
    since fingerprint: FileFingerprint,
    path: String
  ) throws {
    guard try FileFingerprint(of: localURL) == fingerprint else {
      throw ItemSyncFailure.dataChanged(path: path)
    }
  }

  /// A chunked upload in flight: which session it belongs to, how much of it
  /// Dropbox has acknowledged, and the hash of exactly those bytes.
  private struct SessionProgress {
    let session: UploadSessionIdentifier

    /// When the session was opened, which is what Dropbox's 48-hour window is
    /// measured against — a resumed session keeps the original moment.
    let startedAt: Date

    var offset: UInt64

    /// The hasher fed every byte Dropbox has acknowledged, or `nil` once an
    /// offset recovery has moved the position and the prefix is unprovable.
    var prefix: DropboxContentHasher?
  }
}
