import SwiftUI
import UIKit

@main
struct MyTagsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task {
                    delegate.app = app
                    await app.start()
                }
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
    var app: AppModel?

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        app?.downloader.backgroundCompletion = completionHandler
    }
}
