import SwiftUI
import libZephyr

/// How the link dialog moves between what it shows and what it hides.
enum LinkAccountAnimation {
  /// How the form opens and closes the code fallback, and shows a failure.
  static let stageChange = Animation.snappy(duration: 0.2)
}

/**
 Dropbox's authorization flow: the page Zephyr opens, and the account approving
 it links.

 One button does the whole thing. Zephyr shows Dropbox's own page in a web
 authentication session, and the approval comes back to the app as a redirect,
 so there is nothing for the user to carry between two applications.

 Underneath it sits the way that flow used to work, collapsed: open the page in
 a browser and paste the code Dropbox prints. It is offered because the redirect
 is the one part of linking that can fail for reasons a new user can neither see
 nor fix — an unregistered URL scheme, a redirect Dropbox declines — and a
 failure there would otherwise leave them with the one thing they came to do and
 no way to do it.

 Both the link sheet and first-run setup drive the same flow, so they share this
 form; a caller that has somewhere to cancel to passes a `cancel` action, and
 the form grows the button for it. A caller with a help topic to point at
 passes the button for it too, and the form seats it at the leading end of the
 same row — where a Mac dialog keeps its help button.
 */
struct LinkAccountForm: View {
  private let help: HelpTopicLink?
  private let cancel: (() -> Void)?
  private let didLink: () -> Void

  @Environment(AppModel.self)
  private var model
  @Environment(\.openURL)
  private var openURL

  @State private var code = ""
  @State private var isEnteringCode = false
  @State private var isLinking = false
  @State private var errorMessage: String?
  @State private var authorization: Task<Void, Never>?
  @FocusState private var isCodeFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.betweenGroups) {
      ConnectHandoffView(
        isReady: isReady && !isLinking,
        isDefaultAction: !isEnteringCode,
        connect: connect
      )
      CodeEntryFallbackView(
        isExpanded: $isEnteringCode,
        code: $code,
        isCodeFocused: $isCodeFocused,
        isReady: isReady,
        openBrowser: openAuthorizationPage
      )
      if let errorMessage {
        LinkFailureView(message: errorMessage)
          .transition(.blurReplace)
      }
      LinkActionsView(
        isLinking: isLinking,
        canLink: canLink,
        showsLink: isEnteringCode,
        help: help,
        cancel: cancel,
        link: link
      )
    }
    .animation(LinkAccountAnimation.stageChange, value: errorMessage)
    .task { await model.beginLink() }
    // The authorization page outlives the form that opened it — it is another
    // process's window — so a form that goes while one is up takes it along.
    .onDisappear { authorization?.cancel() }
  }

  private var trimmedCode: String {
    code.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canLink: Bool {
    !trimmedCode.isEmpty && !isLinking && isReady
  }

  /// Whether the link flows have been built, which is what everything the form
  /// offers is waiting on.
  private var isReady: Bool { model.pendingLink != nil }

  /// Whether reaching Dropbox really leaves the app. A staged capture run holds
  /// it back; every other launch goes.
  private var opensDropbox: Bool {
    #if DEBUG
      ScreenshotStaging.opensDropbox
    #else
      true
    #endif
  }

  init(
    help: HelpTopicLink? = nil,
    cancel: (() -> Void)? = nil,
    didLink: @escaping () -> Void = {}
  ) {
    self.help = help
    self.cancel = cancel
    self.didLink = didLink
  }

  /**
   Runs Dropbox's authorization page and links whatever the user approves there.

   Closing the page without approving reports nothing: the user asked for that,
   and the form is already showing the way to ask again.
   */
  private func connect() {
    guard !isLinking, opensDropbox else { return }
    isLinking = true
    errorMessage = nil
    authorization = Task {
      do {
        try await model.authorize()
        didLink()
      } catch is CancellationError {
      } catch {
        errorMessage = ErrorSentence.describe(error, includingRecovery: true)
      }
      isLinking = false
    }
  }

  /// Opens the authorization page in the browser for the fallback, and hands
  /// the keyboard to the field the code it prints goes in.
  private func openAuthorizationPage() {
    guard let flow = model.pendingLink?.code else { return }
    if opensDropbox { openURL(flow.authorizationURL) }
    isCodeFocused = true
  }

  private func link() {
    guard !isLinking else { return }
    isLinking = true
    errorMessage = nil
    Task {
      do {
        try await model.completeLink(code: trimmedCode)
        code = ""
        didLink()
      } catch {
        errorMessage = ErrorSentence.describe(error, includingRecovery: true)
      }
      isLinking = false
    }
  }
}

/// What linking is about to do, and the button that does it.
private struct ConnectHandoffView: View {
  let isReady: Bool
  let isDefaultAction: Bool
  let connect: () -> Void

  var body: some View {
    Button(LocalizedStringResource("Connect Dropbox Account…", bundle: #bundle), action: connect)
      .keyboardShortcut(isDefaultAction ? .defaultAction : nil)
      .disabled(!isReady)
      .accessibilityIdentifier("connectDropboxButton")
  }
}

/**
 The way to link without the redirect: the browser, and the code Dropbox prints
 in it.

 Collapsed until asked for, because it is the longer way round and the shorter
 one works. Open, it is the two steps in the order they are taken — the page
 first, then the field for what the page shows.

 The field is monospaced, because an authorization code is read one character at
 a time: someone checking a pasted code against the browser needs `l` and `1` to
 look different.
 */
private struct CodeEntryFallbackView: View {
  @Binding var isExpanded: Bool
  @Binding var code: String
  @FocusState.Binding var isCodeFocused: Bool
  let isReady: Bool
  let openBrowser: () -> Void

  var body: some View {
    VStack(alignment: .leading) {
      QuietButton(
        title: LocalizedStringResource("Enter a code instead", bundle: #bundle),
        symbol: isExpanded ? "chevron.up" : "chevron.down",
        accessibilityIdentifier: "enterCodeInsteadButton"
      ) {
        isExpanded.toggle()
      }
      if isExpanded {
        VStack(alignment: .leading) {
          Text(
            "Open Dropbox in your browser, approve access, then paste the code it shows here.",
            bundle: #bundle
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          QuietButton(
            title: LocalizedStringResource("Open Dropbox in Browser", bundle: #bundle),
            symbol: "arrowshape.right.circle.fill",
            accessibilityIdentifier: "openDropboxButton",
            action: openBrowser
          )
          .disabled(!isReady)
          TextField(LocalizedStringResource("Authorization code", bundle: #bundle), text: $code)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .focused($isCodeFocused)
            .accessibilityIdentifier("authorizationCodeField")
        }
        .transition(.blurReplace)
      }
    }
    .animation(LinkAccountAnimation.stageChange, value: isExpanded)
  }
}

/**
 A step the form offers without asking for it: secondary text with the symbol
 that says where pressing it leads.

 Plain text rather than a link, so that nothing in the form competes with the
 one button the user came here to press.
 */
private struct QuietButton: View {
  let title: LocalizedStringResource
  let symbol: String
  let accessibilityIdentifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Metrics.beforeTrailingSymbol) {
        Text(title)
        Image(systemName: symbol)
          .accessibilityHidden(true)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

/**
 What the link failed on, in the treatment the accounts window gives a failure
 that stopped an account outright: the alert symbol, and the reason beside it.

 The symbol carries no meaning the message does not, so it is left out of the
 accessibility tree rather than read aloud ahead of the sentence it decorates.
 */
private struct LinkFailureView: View {
  let message: String

  var body: some View {
    Label {
      Text(message)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("linkErrorMessage")
    } icon: {
      Image(systemName: "exclamationmark.octagon.fill")
        .accessibilityHidden(true)
    }
    .foregroundStyle(ZephyrPalette.alert)
  }
}

/// The form's buttons: the help button at the leading end, what it shows while
/// a link is in flight, the way out for a caller that has one, and the link
/// itself once the code fallback is open to link from.
private struct LinkActionsView: View {
  let isLinking: Bool
  let canLink: Bool
  let showsLink: Bool
  let help: HelpTopicLink?
  let cancel: (() -> Void)?
  let link: () -> Void

  var body: some View {
    HStack {
      help
      // Beside the help link rather than across the row from it: the buttons
      // this progress would otherwise sit with are absent on the setup page,
      // which leaves it stranded at the far edge from the button it reports on.
      if isLinking {
        HStack {
          Text("Linking…", bundle: #bundle)
          ProgressView()
            .controlSize(.small)
        }
      }
      Spacer()
      if let cancel {
        Button(LocalizedStringResource("Cancel", bundle: #bundle), role: .cancel) { cancel() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("cancelLinkButton")
      }
      if showsLink {
        Button(LocalizedStringResource("Link", bundle: #bundle)) { link() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canLink)
          .accessibilityIdentifier("confirmLinkButton")
      }
    }
  }
}

#if DEBUG
  #Preview("Link form") {
    LinkAccountForm(
      help: HelpTopicLink(anchor: .linkAccount, accessibilityIdentifier: "preview.help"),
      cancel: {}
    )
    .environment(PreviewHelper.model())
    .padding()
    .frame(width: 420)
  }

  #Preview("Link form, nowhere to cancel to") {
    LinkAccountForm()
      .environment(PreviewHelper.model())
      .padding()
      .frame(width: 420)
  }

  #Preview("Connect, flow not ready") {
    ConnectHandoffView(isReady: false, isDefaultAction: true, connect: {})
      .padding()
      .frame(width: 420)
  }

  #Preview("Code fallback, open") {
    @Previewable @State var isExpanded = true
    @Previewable @State var code = "ABCdef1l0O-9_gHijkLmnop"
    @Previewable @FocusState var isCodeFocused: Bool
    CodeEntryFallbackView(
      isExpanded: $isExpanded,
      code: $code,
      isCodeFocused: $isCodeFocused,
      isReady: true,
      openBrowser: {}
    )
    .padding()
    .frame(width: 420)
  }

  #Preview("Rejected code") {
    LinkFailureView(
      message: "Dropbox authentication failed. Dropbox rejected the authorization code or "
        + "refresh token."
    )
    .padding()
    .frame(width: 420)
  }

  #Preview("Link in flight") {
    LinkActionsView(
      isLinking: true,
      canLink: false,
      showsLink: true,
      help: HelpTopicLink(anchor: .linkAccount, accessibilityIdentifier: "preview.help"),
      cancel: {},
      link: {}
    )
    .padding()
    .frame(width: 420)
  }
#endif
