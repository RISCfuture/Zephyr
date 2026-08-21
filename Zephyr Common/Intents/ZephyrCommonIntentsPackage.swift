import AppIntents
import libZephyr

/**
 The App Intents `ZephyrCommon` defines, and those it carries up from
 `libZephyr`.

 Both editions link this framework rather than defining app-layer code
 themselves, so the chain from `libZephyr` to an app target runs through here:
 each edition's package names this one, and this one names `ZephyrIntentsPackage`.
 */
public struct ZephyrCommonIntentsPackage: AppIntentsPackage {
  public static var includedPackages: [any AppIntentsPackage.Type] {
    [ZephyrIntentsPackage.self]
  }
}
