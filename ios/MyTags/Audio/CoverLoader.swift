import SwiftUI
import UIKit

/// Covers in two sizes (150 px for lists, 600 px for the Tag screen), cached in memory and on disk.
actor CoverLoader {
    enum Size: Int, Sendable {
        case small = 150
        case large = 600
    }

    private let folder: URL
    private nonisolated let memory = ImageMemoryCache()
    private var api: APIClient?
    private var inFlight: [String: Task<Fetched, Never>] = [:]
    /// Covers the server does not have (404), not asked again until the network comes back.
    private var missing: Set<String> = []

    /// A downloaded cover, or none; only a 404 means the cover does not exist.
    private struct Fetched: Sendable {
        var image: UIImage?
        var isMissing = false
    }

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appending(path: "Covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func configure(api: APIClient?) {
        self.api = api
        missing.removeAll()
    }

    /// Memory-only lookup, usable synchronously from views through `cachedImage`.
    nonisolated func cachedImage(coverKey: String?, size: Size) -> UIImage? {
        guard let coverKey else { return nil }
        return memory.image(forKey: "\(coverKey)_\(size.rawValue)")
    }

    func image(coverKey: String?, size: Size) async -> UIImage? {
        guard let coverKey else { return nil }
        let name = "\(coverKey)_\(size.rawValue)"
        if let cached = memory.image(forKey: name) { return cached }
        let file = folder.appending(path: name.replacingOccurrences(of: "/", with: "_") + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            let decoded = await image.byPreparingForDisplay() ?? image
            memory.set(decoded, forKey: name)
            return decoded
        }
        if missing.contains(name) { return nil }
        if let running = inFlight[name] { return await running.value.image }
        guard let api else { return nil }
        let task = Task<Fetched, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(for: api.blobRequest(key: "\(name).jpg"))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let image = UIImage(data: data) else {
                    return Fetched(image: nil, isMissing: status == 404)
                }
                try? data.write(to: file, options: .atomic)
                return Fetched(image: await image.byPreparingForDisplay() ?? image)
            } catch {
                return Fetched(image: nil)
            }
        }
        inFlight[name] = task
        let fetched = await task.value
        inFlight[name] = nil
        if let image = fetched.image {
            memory.set(image, forKey: name)
        } else if fetched.isMissing {
            missing.insert(name)
        }
        return fetched.image
    }

    /// Fetches missing thumbnails in the background (Wi-Fi), a few at a time.
    func prefetchThumbnails(_ coverKeys: [String]) async {
        let todo = coverKeys.filter { key in
            let file = folder.appending(path: "\(key)_150".replacingOccurrences(of: "/", with: "_") + ".jpg")
            return !FileManager.default.fileExists(atPath: file.path)
        }
        for chunk in todo.chunked(into: 4) {
            if Task.isCancelled { return }
            await withTaskGroup(of: Void.self) { group in
                for key in chunk {
                    group.addTask { _ = await self.image(coverKey: key, size: .small) }
                }
            }
        }
    }

    func clearMissing() {
        missing.removeAll()
    }
}

/// NSCache is thread-safe but not annotated as Sendable.
final class ImageMemoryCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// Cover image that loads asynchronously, with a quiet placeholder.
struct CoverImage: View {
    let coverKey: String?
    let size: CoverLoader.Size
    let side: CGFloat
    var cornerRadius: CGFloat = Theme.coverCornerRadius

    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.3))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: coverKey) {
            image = app.covers.cachedImage(coverKey: coverKey, size: size)
            if image == nil {
                let loaded = await app.covers.image(coverKey: coverKey, size: size)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
        }
    }
}
