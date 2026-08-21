import Foundation

/**
 The pages of first-run setup, in the order Zephyr walks through them.

 Zephyr asks for nothing before it has explained what it will ask for, and it
 can't ask macOS to enable a File Provider until an account has given it a
 domain to enable — so the order is fixed rather than chosen per launch.
 */
enum SetupStep: CaseIterable, Identifiable, Sendable {
  case welcome
  case whatZephyrNeeds
  case account
  case finderExtension
  case notifications
  case loginItem
  case ready

  var id: Self { self }

  var next: Self? {
    Self.allCases.indices.contains(position + 1) ? Self.allCases[position + 1] : nil
  }

  var previous: Self? {
    Self.allCases.indices.contains(position - 1) ? Self.allCases[position - 1] : nil
  }

  private var position: Int {
    guard let position = Self.allCases.firstIndex(of: self) else {
      preconditionFailure("\(self) is missing from SetupStep.allCases")
    }
    return position
  }
}
