import Foundation

/**
 A description of one Dropbox API route: which host serves it, how arguments and
 results are carried, and whether it is authenticated.

 Route URLs have the shape `https://{host}/2/{namespace}/{name}`.
 */
struct DropboxRoute: Sendable {

  /// The default per-request timeout used by most routes.
  static let defaultTimeout: Duration = .seconds(100)

  let host: Host
  let namespace: String
  let name: String
  let style: Style
  let isAuthenticated: Bool
  let timeout: Duration

  /// The full request URL for this route.
  var url: URL {
    URL(string: "https://\(host.authority)/2/\(namespace)/\(name)")!
  }

  /// The route identifier used in diagnostics, e.g. `files/list_folder`.
  var identifier: String { "\(namespace)/\(name)" }

  init(
    host: Host,
    namespace: String,
    name: String,
    style: Style = .rpc,
    isAuthenticated: Bool = true,
    timeout: Duration = Self.defaultTimeout
  ) {
    self.host = host
    self.namespace = namespace
    self.name = name
    self.style = style
    self.isAuthenticated = isAuthenticated
    self.timeout = timeout
  }

  /// The Dropbox API host families.
  enum Host: Sendable {
    /// `api.dropboxapi.com` — RPC routes with JSON bodies.
    case api
    /// `content.dropboxapi.com` — upload and download routes.
    case content
    /// `notify.dropboxapi.com` — the longpoll route; requires no authentication.
    case notify

    var authority: String {
      switch self {
        case .api: "api.dropboxapi.com"
        case .content: "content.dropboxapi.com"
        case .notify: "notify.dropboxapi.com"
      }
    }
  }

  /// How a route carries its arguments and result.
  enum Style: Sendable {
    /// Arguments as the JSON request body; result as the JSON response body.
    case rpc
    /// Arguments in the `Dropbox-API-Arg` header; content as the request body.
    case upload
    /// Arguments in the `Dropbox-API-Arg` header; result metadata in the
    /// `Dropbox-API-Result` response header; content as the response body.
    case download
  }
}
