public import AppIntents

/**
 The App Intents `libZephyr` defines.

 App Intents metadata is extracted per target, and a framework's does not
 reach the app that links it on its own. Declaring a package here, and naming
 it from the package each app target declares, is what carries these intents
 into the app's own `Metadata.appintents`.
 */
public struct ZephyrIntentsPackage: AppIntentsPackage {}
