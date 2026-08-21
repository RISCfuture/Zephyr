import Foundation
import ServiceManagement

/// Registers and unregisters the app as a login item, so sync signaling and
/// notifications run without the user launching Zephyr by hand.
enum LaunchAtLogin {
  /// Whether the app is currently registered to launch at login.
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Registers or unregisters the login item.
  static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
