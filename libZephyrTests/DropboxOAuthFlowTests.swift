import Foundation
import Testing

@testable import libZephyr

@Suite
struct DropboxOAuthFlowTests {
  private static let appKey = "testappkey"
  private static let tokenResponseJSON = """
    {"access_token": "sl.access", "token_type": "bearer", "expires_in": 14400,
     "refresh_token": "sl.refresh", "account_id": "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc",
     "scope": "files.content.write", "uid": "12345"}
    """

  private static func queryItems(of url: URL) throws -> [String: String] {
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    return (components.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value }
  }

  private static func formBody(of transport: MockTransport) async throws -> [String: String] {
    let request = try #require(await transport.requests.last)
    let httpBody = try #require(request.httpBody)
    let body = try #require(String(bytes: httpBody, encoding: .utf8))
    return body.split(separator: "&").reduce(into: [:]) { form, pair in
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { return }
      form[String(parts[0])] = String(parts[1]).removingPercentEncoding
    }
  }

  private func makeFlow(
    redirect: DropboxOAuthFlow.RedirectStyle,
    transport: MockTransport
  ) -> DropboxOAuthFlow {
    DropboxOAuthFlow(appKey: Self.appKey, redirect: redirect, transport: transport)
  }

  @Test
  func authorizationURLAdvertisesTheChallengeAndTheCallbackStyle() throws {
    let outOfBand = makeFlow(redirect: .outOfBand, transport: MockTransport())
    let customScheme = makeFlow(redirect: .customScheme, transport: MockTransport())

    let outOfBandQuery = try Self.queryItems(of: outOfBand.authorizationURL)
    #expect(
      outOfBand.authorizationURL.absoluteString.hasPrefix(
        "https://www.dropbox.com/oauth2/authorize?"
      )
    )
    #expect(outOfBandQuery["response_type"] == "code")
    #expect(outOfBandQuery["client_id"] == Self.appKey)
    // Offline access is what earns the refresh token the app stores.
    #expect(outOfBandQuery["token_access_type"] == "offline")
    #expect(outOfBandQuery["code_challenge"] == outOfBand.verifier.challenge)
    #expect(outOfBandQuery["code_challenge_method"] == "S256")
    #expect(outOfBandQuery["state"] == outOfBand.state)
    // Out-of-band means no redirect: Dropbox shows the code instead.
    #expect(outOfBand.redirectURI == nil)
    #expect(outOfBandQuery["redirect_uri"] == nil)

    #expect(customScheme.redirectURI == "db-\(Self.appKey)://oauth")
    #expect(
      try Self.queryItems(of: customScheme.authorizationURL)["redirect_uri"]
        == "db-\(Self.appKey)://oauth"
    )
  }

  @Test
  func exchangingAPastedCodeProvesThePKCEVerifierAndReturnsTheLink() async throws {
    let transport = MockTransport()
    let flow = makeFlow(redirect: .outOfBand, transport: transport)
    await transport.enqueueJSON(Self.tokenResponseJSON)

    let link = try await flow.exchange(code: "  pasted-code\n")

    let request = try #require(await transport.requests.last)
    #expect(request.url?.absoluteString == "https://api.dropboxapi.com/oauth2/token")
    #expect(request.httpMethod == "POST")
    #expect(
      request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
    )
    let form = try await Self.formBody(of: transport)
    #expect(form["grant_type"] == "authorization_code")
    // Whitespace around a code pasted from a browser must not reach Dropbox.
    #expect(form["code"] == "pasted-code")
    #expect(form["client_id"] == Self.appKey)
    // The challenge advertised in the authorization URL is redeemed with this verifier.
    #expect(form["code_verifier"] == flow.verifier.value)
    #expect(form["redirect_uri"] == nil)

    #expect(link.accountID.rawValue == "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc")
    #expect(link.refreshToken == "sl.refresh")
    #expect(link.accessToken == "sl.access")
    #expect(link.accessTokenExpiry.timeIntervalSinceNow > 14_000)
  }

  @Test
  func aCallbackCarryingTheFlowsStateExchangesWithTheRedirectURI() async throws {
    let transport = MockTransport()
    let flow = makeFlow(redirect: .customScheme, transport: transport)
    await transport.enqueueJSON(Self.tokenResponseJSON)
    let callback = try #require(
      URL(string: "db-\(Self.appKey)://oauth?code=callback-code&state=\(flow.state)")
    )

    let link = try await flow.exchange(callbackURL: callback)

    let form = try await Self.formBody(of: transport)
    #expect(form["code"] == "callback-code")
    #expect(form["code_verifier"] == flow.verifier.value)
    // Dropbox validates the redirect URI against the authorization request.
    #expect(form["redirect_uri"] == "db-\(Self.appKey)://oauth")
    #expect(link.refreshToken == "sl.refresh")
  }

  @Test(arguments: ["", "&state=someone-elses-state"])
  func aCallbackFailingItsStateCheckNeverReachesTheTokenEndpoint(
    _ stateQuery: String
  ) async throws {
    let transport = MockTransport()
    let flow = makeFlow(redirect: .customScheme, transport: transport)
    let callback = try #require(
      URL(string: "db-\(Self.appKey)://oauth?code=callback-code\(stateQuery)")
    )

    do {
      _ = try await flow.exchange(callbackURL: callback)
      Issue.record("exchange(callbackURL:) should have thrown stateMismatch")
    } catch AuthenticationFailure.stateMismatch {
    } catch {
      Issue.record("Expected AuthenticationFailure.stateMismatch, got \(error)")
    }

    // A callback that fails its integrity check never reaches Dropbox.
    #expect(await transport.requests.isEmpty)
  }

  @Test
  func aRefusedAuthorizationSurfacesWhyRatherThanAMissingCode() async throws {
    let transport = MockTransport()
    let flow = makeFlow(redirect: .customScheme, transport: transport)
    let declined = try #require(
      URL(
        string: "db-\(Self.appKey)://oauth?error=access_denied"
          + "&error_description=The%20user%20chose%20not%20to%20give%20access&state=\(flow.state)"
      )
    )

    do {
      _ = try await flow.exchange(callbackURL: declined)
      Issue.record("exchange(callbackURL:) should have thrown authorizationDeclined")
    } catch AuthenticationFailure.authorizationDeclined {
    } catch {
      Issue.record("Expected AuthenticationFailure.authorizationDeclined, got \(error)")
    }

    let rejected = try #require(
      URL(
        string: "db-\(Self.appKey)://oauth?error=invalid_scope"
          + "&error_description=Requested+scope+is+unknown&state=\(flow.state)"
      )
    )
    do {
      _ = try await flow.exchange(callbackURL: rejected)
      Issue.record("exchange(callbackURL:) should have thrown authorizationRejected")
    } catch AuthenticationFailure.authorizationRejected(let reason) {
      // Dropbox form-encodes the redirect query, so its spaces arrive as "+".
      #expect(reason == "Requested scope is unknown")
    } catch {
      Issue.record("Expected AuthenticationFailure.authorizationRejected, got \(error)")
    }

    #expect(await transport.requests.isEmpty)
  }

  @Test
  func aTokenResponseWithoutARefreshTokenIsMalformed() async throws {
    let transport = MockTransport()
    let flow = makeFlow(redirect: .outOfBand, transport: transport)
    // A short-lived-token app registration answers an exchange without the
    // refresh token and account the app needs to persist the link.
    await transport.enqueueJSON(
      #"{"access_token": "sl.access", "token_type": "bearer", "expires_in": 14400}"#
    )

    do {
      _ = try await flow.exchange(code: "pasted-code")
      Issue.record("exchange(code:) should have thrown malformedTokenResponse")
    } catch AuthenticationFailure.malformedTokenResponse(let detail) {
      #expect(detail.contains("refresh token"))
    } catch {
      Issue.record("Expected AuthenticationFailure.malformedTokenResponse, got \(error)")
    }
  }
}
