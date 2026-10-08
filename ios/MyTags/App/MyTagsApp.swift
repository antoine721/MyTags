import SwiftUI
import UIKit

@main
struct MyTagsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Created here, not when a window appears: iOS can relaunch the app in the background for
        // trip downloads, and the delegate needs the model (and its download session) right away.
        let app = AppModel()
        _app = State(initialValue: app)
        AppDelegate.app = app
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
                .onOpenURL { app.handleOpenURL($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: app.sceneBecameActive()
            case .background: app.sceneEnteredBackground()
            default: break
            }
        }
    }
}

/// Receives the completion handler iOS passes when trip downloads finish in the background.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set in `MyTagsApp.init`, before any delegate callback (the model owns the download session).
    @MainActor static var app: AppModel?

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Stored statically and called by the Downloader once the session has delivered its events,
        // even if that happens before or without a window.
        Downloader.backgroundCompletion = completionHandler
    }
}
