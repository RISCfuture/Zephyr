import FileProvider
import ServiceManagement
import SwiftUI
import UserNotifications
import libZephyr

/**
 Something macOS grants outside Zephyr, and which part of Zephyr stops working
 without.

 Each case is detectable but not grantable: Zephyr can tell that the user has
 withheld it, and can open the pane that grants it, but only the user can turn
 it on.
 */
enum SystemApproval: String, CaseIterable, Identifiable, Sendable {
  /// The File Provider extension Finder serves a linked account's files through.
  case finderExtension

  /// Notification authorization, without which changes and sync issues go unannounced.
  case notifications

  /// The login item, registered by Zephyr but switched off by the user.
  case loginItem

  var id: String { rawValue }

  /// The command that grants it, for a surface with room for a menu item
  /// rather than a sentence. It ends in an ellipsis because granting it
  /// happens in System Settings.
  var actionTitle: LocalizedStringResource {
    switch self {
      case .finderExtension:
        LocalizedStringResource("Enable Zephyr in Finder…", bundle: #bundle)
      case .notifications:
        LocalizedStringResource("Allow Zephyr’s Notifications…", bundle: #bundle)
      case .loginItem:
        LocalizedStringResource("Allow Zephyr to Open at Login…", bundle: #bundle)
    }
  }

  /// What stops working without it, in the terms the user meets it in.
  var summary: LocalizedStringResource {
    switch self {
      case .finderExtension:
        LocalizedStringResource(
          "A linked account’s files can’t appear in Finder until Zephyr’s File Provider extension is enabled.",
          bundle: #bundle
        )
      case .notifications:
        LocalizedStringResource(
          "Zephyr can’t report file changes or sync issues until notifications are allowed.",
          bundle: #bundle
        )
      case .loginItem:
        LocalizedStringResource(
          "Finder learns about remote changes within seconds only while Zephyr is allowed to open at login.",
          bundle: #bundle
        )
    }
  }

  /**
   The help-book topic for an approval that is being withheld.

   Each names the page about *this* being missing rather than one page about
   approvals in general: a reader whose Dropbox never appeared in Finder and a
   reader who is not seeing notifications have different problems, and a help
   button that lands them both on the same page is a help button that lied to
   one of them.
   */
  var helpAnchor: HelpAnchor {
    switch self {
      case .finderExtension: .dropboxNotInFinder
      case .notifications: .notificationsDenied
      case .loginItem: .withheldApproval
    }
  }

  /// The System Settings pane that grants it.
  var settingsURL: URL {
    switch self {
      case .finderExtension: SystemSettings.fileProviders
      case .loginItem: SystemSettings.loginItemsAndExtensions
      case .notifications: SystemSettings.notifications
    }
  }

  /// Where in System Settings the button lands.
  var settingsHint: LocalizedStringResource {
    switch self {
      case .finderExtension:
        LocalizedStringResource(
          "Open File Providers, where Zephyr is switched on for Finder",
          bundle: #bundle
        )
      case .notifications:
        LocalizedStringResource("Open Notifications, where Zephyr’s are allowed", bundle: #bundle)
      case .loginItem:
        LocalizedStringResource(
          "Open Login Items & Extensions, where Zephyr’s login item is allowed",
          bundle: #bundle
        )
    }
  }
}

/// Reads what macOS is granting Zephyr and what it is withholding.
@MainActor
enum SystemApprovalAudit {
  /// The login item is registered, but the user has switched it off.
  private static var isLoginItemWithheld: Bool {
    SMAppService.mainApp.status == .requiresApproval
  }

  /**
   Every approval the user needs to grant, most consequential first.

   This answers "what should Zephyr complain about", so it stays quiet
   about anything the user hasn't been asked for yet — an unregistered
   login item is a preference, not a refusal.
   */
  static func withheldApprovals() async -> [SystemApproval] {
    var withheld: [SystemApproval] = []
    if await isFinderExtensionWithheld() { withheld.append(.finderExtension) }
    if await areNotificationsWithheld() { withheld.append(.notifications) }
    if isLoginItemWithheld { withheld.append(.loginItem) }
    return withheld
  }

  /**
   Whether macOS is granting an approval right now.

   This is the question setup asks, and it is not the negation of
   ``withheldApprovals()``: an approval that has never been requested is
   neither granted nor withheld.
   */
  static func isGranted(_ approval: SystemApproval) async -> Bool {
    switch approval {
      case .finderExtension: await isFinderExtensionEnabled()
      case .notifications: await notificationAuthorizationStatus() == .authorized
      case .loginItem: SMAppService.mainApp.status == .enabled
    }
  }

  /// Asks macOS for notification authorization, showing its prompt when the
  /// user hasn't answered before; a user who already refused sees nothing,
  /// which is why setup sends them to System Settings instead.
  static func requestNotificationAuthorization() async -> Bool {
    (try? await UNUserNotificationCenter.current()
      .requestAuthorization(options: [.alert, .sound])) ?? false
  }

  /// Whether the user has already answered the notification prompt.
  static func hasAnsweredNotificationPrompt() async -> Bool {
    await notificationAuthorizationStatus() != .notDetermined
  }

  /// Every registered domain is enabled — false when none is registered,
  /// since an account that isn't linked has nothing to enable yet.
  private static func isFinderExtensionEnabled() async -> Bool {
    guard let domains = try? await NSFileProviderManager.domains(), !domains.isEmpty
    else { return false }
    return domains.allSatisfy(\.userEnabled)
  }

  /// A registered domain the user has switched off under File Providers: the
  /// account is linked and its index is current, but Finder won't show it.
  private static func isFinderExtensionWithheld() async -> Bool {
    guard let domains = try? await NSFileProviderManager.domains() else { return false }
    return domains.contains { !$0.userEnabled }
  }

  /// Denied notifications, which only matter while Zephyr is set to post any.
  private static func areNotificationsWithheld() async -> Bool {
    guard NotificationSettings.load().level != .none else { return false }
    return await notificationAuthorizationStatus() == .denied
  }

  /// Reads the status through the callback API: `UNNotificationSettings` is
  /// not `Sendable`, so only the status itself may leave the callback.
  private static func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        continuation.resume(returning: settings.authorizationStatus)
      }
    }
  }
}
