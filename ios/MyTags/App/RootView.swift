import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.phase {
            case .launching:
                Color(uiColor: .systemBackground)
            case .pairing:
                PairingView()
            case .ready:
                LibraryView()
                    .fullScreenCover(isPresented: $app.isTagScreenPresented, onDismiss: {
                        if app.tagSession != nil { app.closeTagScreen() }
                    }) {
                        if let session = app.tagSession {
                            TagScreen(session: session)
                                .environment(app)
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.phase)
    }
}
