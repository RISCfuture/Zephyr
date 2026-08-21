import Foundation

extension DropboxClient {
  /// The most accounts `users/get_account_batch` names in one request.
  private static var accountBatchLimit: Int { 300 }

  /// Fetches the linked account's full details.
  public func currentAccount() async throws -> FullAccount {
    try await rpc(
      DropboxRoute(host: .api, namespace: "users", name: "get_current_account"),
      argument: NullArgument()
    )
  }

  /// Fetches the account's storage usage.
  public func spaceUsage() async throws -> SpaceUsage {
    try await rpc(
      DropboxRoute(host: .api, namespace: "users", name: "get_space_usage"),
      argument: NullArgument()
    )
  }

  /// Fetches the publicly visible details of one other account.
  func account(_ id: AccountIdentifier) async throws -> BasicAccount {
    struct Argument: Encodable {
      let accountID: String

      enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
      }
    }
    return try await rpc(
      DropboxRoute(host: .api, namespace: "users", name: "get_account"),
      argument: Argument(accountID: id.rawValue)
    )
  }

  /**
   Fetches the publicly visible details of several accounts, splitting the
   request into the batches `users/get_account_batch` accepts.

   Dropbox fails a whole batch when it will not name one of its members, so
   callers that want partial answers fall back to ``account(_:)``.
   */
  func accounts(_ ids: [AccountIdentifier]) async throws -> [BasicAccount] {
    var accounts: [BasicAccount] = []
    for start in stride(from: 0, to: ids.count, by: Self.accountBatchLimit) {
      let batch = ids[start..<min(start + Self.accountBatchLimit, ids.count)]
      accounts += try await accountBatch(Array(batch))
    }
    return accounts
  }

  private func accountBatch(_ ids: [AccountIdentifier]) async throws -> [BasicAccount] {
    struct Argument: Encodable {
      let accountIDs: [String]

      enum CodingKeys: String, CodingKey {
        case accountIDs = "account_ids"
      }
    }
    return try await rpc(
      DropboxRoute(host: .api, namespace: "users", name: "get_account_batch"),
      argument: Argument(accountIDs: ids.map(\.rawValue))
    )
  }

  /// Revokes this client's access token pair server-side.
  public func revokeToken() async throws {
    try await rpcVoid(
      DropboxRoute(host: .api, namespace: "auth", name: "token/revoke"),
      argument: NullArgument()
    )
  }
}
