import AVFoundation
import Foundation
import GRDB
import MyTagsKit

/// Demo library: the starting field configuration and invented tracks, to try the Tag screen
/// before the cloud is set up (spec phase 2). Nothing is sent anywhere.
enum DemoData {
    static let artists = [
        "Kalash", "Ninho feat. Jul", "Admiral T", "Aya Nakamura", "Dadju & Tayc", "Kaza", "Joé Dwèt Filé",
        "Drake", "SZA", "Burna Boy", "Tiakola", "Franglish", "Keros-n", "Lyrrix", "Wizkid",
    ]
    static let titles = [
        "Mwen Kontan", "Bad Gyal", "Nuit Blanche", "Shatta Wave", "Pa Lagé Mwen", "Million", "Sexy Lady",
        "Midnight", "Ocean Drive", "Bouyon Fever", "Love Nwar", "Zouk Machine", "Wine Up", "Tchiki",
        "Dancehall Queen", "Soleil", "Kompa Love", "Lavi", "Paradise", "La Vie",
    ]
    static let variants = ["", " (Extended Mix)", " (Remix)", " (Radio Edit)", " (DJ Edit)", ""]
    static let keys = ["8A", "9A", "10B", "4A", "11B", "5A", "2B"]

    static func install(into database: AppDatabase) {
        guard let url = Bundle.main.url(forResource: "default-config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? ConfigDocument.decode(from: data)
        else { return }
        try? database.saveConfig(
            DirtyConfig(fields: document.fields, fieldOptions: document.fieldOptions, rules: document.rules,
                        savedViews: document.savedViews, settings: document.settings),
            dirty: false)
        var generator = SystemRandomNumberGenerator()
        let encoder = JSONEncoder()
        let now = Timestamp.string(from: Date())
        let genres = ["RAP FR", "Shatta", "Bouyon", "", "", "POP", "Zouk"]
        try? database.pool.write { db in
            for index in 0..<48 {
                let artist = artists[index % artists.count]
                let title = titles[(index * 7) % titles.count] + variants[index % variants.count]
                let bpm = Double([96, 100, 104, 110, 120, 128, 140][index % 7])
                let duration = 150_000 + (index * 7_919) % 90_000
                let genre = genres[index % genres.count]
                let comment = index % 5 == 0 ? "fr extend sexy" : (index % 7 == 0 ? "8A - Energy 6" : "")
                let track = Track(
                    id: UUID().uuidString.lowercased(), filePath: "/Demo/\(artist) - \(title).mp3", fileFormat: "mp3",
                    title: title, artist: artist, bpm: bpm, musicalKey: keys[index % keys.count], durationMs: duration,
                    addedAt: now, startMs: duration / 3, waveform: waveform(seed: index, using: &generator),
                    audioKey: nil, baseline: Baseline(genre: genre.isEmpty ? nil : genre, comment: comment.isEmpty ? nil : comment),
                    applyStatus: .aucun, updatedAt: now)
                try db.execute(sql: "INSERT OR REPLACE INTO tracks (id, json) VALUES (?, ?)",
                               arguments: [track.id, try encoder.encode(track)])
            }
        }
    }

    private static func waveform(seed: Int, using generator: inout SystemRandomNumberGenerator) -> String {
        var bytes = [UInt8](repeating: 0, count: 600)
        for i in 0..<600 {
            let envelope = sin(Double(i) / 600 * .pi) * 0.6 + 0.4
            let beat = (i + seed) % 8 < 2 ? 1.0 : 0.65
            bytes[i] = UInt8(min(255, max(8, Double.random(in: 0.75...1, using: &generator) * envelope * beat * 255)))
        }
        return Data(bytes).base64EncodedString()
    }
}

/// Short generated drum loops at each demo track's BPM, so playback can be tried without a server.
enum DemoAudio {
    @MainActor
    static func generate(for tracks: [Track], cache: AudioCache) async {
        for track in tracks {
            let bpm = track.bpm ?? 120
            let id = track.id
            let file = FileManager.default.temporaryDirectory.appending(path: "\(id).m4a")
            let ok = await Task.detached(priority: .utility) { render(bpm: bpm, seconds: 40, to: file) }.value
            if ok {
                try? cache.store(trackID: id, downloadedFile: file, kind: .auto)
            }
        }
    }

    private nonisolated static func render(bpm: Double, seconds: Double, to url: URL) -> Bool {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return false }
        let frames = AVAudioFrameCount(rate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1]
        else { return false }
        buffer.frameLength = frames
        let beat = 60 / bpm
        for n in 0..<Int(frames) {
            let t = Double(n) / rate
            let inBeat = t.truncatingRemainder(dividingBy: beat)
            let kick = inBeat < 0.25 ? sin(2 * .pi * (55 + 90 * exp(-inBeat * 30)) * inBeat) * exp(-inBeat * 9) : 0
            let off = (t + beat / 2).truncatingRemainder(dividingBy: beat)
            let hat = off < 0.05 ? Double.random(in: -1...1) * exp(-off * 80) * 0.25 : 0
            let pad = sin(2 * .pi * 220 * t) * 0.05 * (0.5 + 0.5 * sin(2 * .pi * t / (beat * 8)))
            let sample = Float((kick * 0.8 + hat + pad) * 0.7)
            left[n] = sample
            right[n] = sample
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000,
        ]
        do {
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
            return true
        } catch {
            return false
        }
    }
}
