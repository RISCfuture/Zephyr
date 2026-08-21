import AppIntents
import Foundation

/// Which account an intent acts as.
enum IntentAccounts {
  /// What a shortcut is asked when several accounts are linked and it named none.
  static var accountPrompt: IntentDialog {
    IntentDialog(LocalizedStringResource("Which Dropbox account?", bundle: .libZephyr))
  }

  /**
   Resolves the account an intent runs against, the way `zephyr` resolves
   `--account`: the one the shortcut names, or the only one Zephyr can
   authenticate as.

   The app and `zephyr` keep their credentials in different keychains, so this
   answers over the accounts the *app* linked. An account linked only from the
   command line is not one a shortcut can act as.

   - Parameters:
     - chosen: The account the shortcut names, or `nil` to take the only one.
     - linked: The accounts Zephyr can authenticate as, from
       ``SharedAccountService/scriptableAccounts()``.
   - Returns: The account to act as, or `nil` when several are linked and the
     shortcut named none — which is the caller's cue to ask.
   - Throws: ``ScriptingFailure/noAccountLinked`` when none is linked. This is
     the shortcut's answer to the condition `zephyr` exits 69 for.
   */
  static func resolve(
    _ chosen: AccountEntity?,
    among linked: [AccountConfiguration]
  ) throws -> AccountIdentifier? {
    if let chosen { return try chosen.accountID }
    guard let sole = linked.first else { throw ScriptingFailure.noAccountLinked }
    guard linked.count == 1 else { return nil }
    return sole.accountID
  }
}
