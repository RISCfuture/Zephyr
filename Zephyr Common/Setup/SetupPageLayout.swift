import AppKit
import SwiftUI
import libZephyr

/**
 The shape every page that asks for something takes: a headline, a paragraph
 explaining why, what the page asks the user to do, and the report of whether
 it has happened yet.

 The four are separate slots rather than one block of content so that this type
 owns all three gaps between them. A page therefore says what it is made of and
 nothing about how far apart it sits, which is what keeps setup's rhythm in one
 place rather than in every page that follows it.

 The report is optional: a page that only tells the user something has nothing
 to report on.
 */
struct SetupPageLayout<Content: View, Status: View>: View {
  let title: LocalizedStringResource
  let message: LocalizedStringResource
  @ViewBuilder let content: Content
  @ViewBuilder let status: Status

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.beforeBody) {
      VStack(alignment: .leading) {
        Text(title)
          .font(.title2)
          .fontWeight(.semibold)
        Text(message)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: Metrics.betweenGroups) {
        content
        status
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension SetupPageLayout where Status == EmptyView {
  init(
    title: LocalizedStringResource,
    message: LocalizedStringResource,
    @ViewBuilder content: () -> Content
  ) {
    self.init(title: title, message: message, content: content) { EmptyView() }
  }
}

/**
 The shape the pages at either end take: the app's icon over a title and a
 sentence, centred with room above and below.

 The pages between these two ask for something, so they hang what they ask off
 the leading edge under a heading. These two only say where the user has
 arrived, and a centred column under the icon is what a Mac welcome window
 looks like.
 */
struct SetupBookendPage<Content: View>: View {
  let title: LocalizedStringResource
  let message: LocalizedStringResource
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: Metrics.betweenGroups) {
      Spacer(minLength: 0)
      AppIcon()
      Text(title)
        .font(.largeTitle)
        .fontWeight(.semibold)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      content
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
  }
}

extension SetupBookendPage where Content == EmptyView {
  init(title: LocalizedStringResource, message: LocalizedStringResource) {
    self.init(title: title, message: message) { EmptyView() }
  }
}

/// Zephyr's own icon, the way a Mac welcome window introduces an app.
private struct AppIcon: View {
  private static let size: CGFloat = 96

  var body: some View {
    Image(nsImage: NSApplication.shared.applicationIconImage)
      .resizable()
      .frame(width: Self.size, height: Self.size)
      .accessibilityHidden(true)
  }
}

#if DEBUG
  extension View {
    /// A setup page framed the way the setup window frames it, so a preview of
    /// one page is comparable with a preview of the next.
    func inSetupWindow() -> some View {
      frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Metrics.pageInsets)
        .frame(width: 580, height: 420)
    }
  }
#endif
