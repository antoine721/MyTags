import SwiftUI
import UIKit

/// The Tag screen's ambience (iOS 26 look): the cover, heavily blurred and muted, behind the top of
/// the screen, fading out before the tag panel. Muted on purpose: the only vivid colors of the app
/// are the Couleur field's (spec 15). Plain background with "Réduire la transparence".
struct CoverBackdrop: View {
    let coverKey: String?

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color(uiColor: .systemBackground)
                if let image, !reduceTransparency {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height * 0.6)
                        .clipped()
                        .blur(radius: 60, opaque: true)
                        .saturation(0.7)
                        .opacity(colorScheme == .dark ? 0.55 : 0.4)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.45),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom))
                        .transition(.opacity)
                        .id(coverKey)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.3), value: coverKey)
        .task(id: coverKey) {
            image = app.covers.cachedImage(coverKey: coverKey, size: .small)
            if image == nil {
                image = await app.covers.image(coverKey: coverKey, size: .small)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
