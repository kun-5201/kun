import SwiftUI
import KumoneIOSFeature

@main
struct KumoneIOSApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate
    var body: some Scene {
        WindowGroup {
            IOSMainWindow()
        }
    }
}

@MainActor
final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        OfflineDownloadEvents.handleBackgroundSession(identifier: identifier, completion: completionHandler)
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // #50: the launch marker is the only witness to a previous launch
        // dying (jetsam / crash) without ending the island — a dead app
        // cannot log its own death, so the next launch logs the leftover
        // activity and the memory footprint instead.
        LyricsLiveActivityManager.shared.noteAppLaunched()
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // #50: the gap since backgrounding is the freeze window, and the
        // island state is re-published at once if the system ended the
        // activity while we were away.
        LyricsLiveActivityManager.shared.noteAppForegrounded()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // #54: marks a clean exit (see noteWillTerminate) so the next
        // launch can tell a clean exit from a crash/jetsam/force-quit.
        LyricsLiveActivityManager.shared.noteWillTerminate()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // #50: log the transition (isPlaying / island / keep-alive /
        // memory) so the next export can tell suspension from death.
        LyricsLiveActivityManager.shared.noteAppBackgrounded()
        // Keep the island while music plays in the background (the Lock
        // Screen relies on it); only end it when already stopped.
        LyricsLiveActivityManager.shared.endForAppShutdownIfNotPlaying()
    }
}

// MARK: - CarPlay

import CarPlay
import UIKit

/// CarPlay template scene delegate — instantiated automatically by UIApplicationSceneManifest in Info.plist.
/// It just forwards the connect/disconnect callbacks into `CarPlayConnector` inside KumoneCore;
/// the app target itself stays as a thin bridge and owns no CarPlay logic of its own.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {}

extension CarPlaySceneDelegate {
    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlayConnector.shared.didConnect(
            interfaceController: interfaceController,
            window: scene.carWindow
        )
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        CarPlayConnector.shared.didDisconnect()
    }
}
