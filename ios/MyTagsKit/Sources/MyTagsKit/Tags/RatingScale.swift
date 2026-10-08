import Foundation

/// Rating scales of the file formats (`docs/modele-tags.md`, section 13).
public enum RatingScale {
    /// How a raw rating is stored.
    public enum Scheme: String, Sendable, CaseIterable {
        /// ID3 POPM byte (MP3, WAV, AIFF).
        case popm
        /// MP4 `RATE` / Vorbis `RATING` of unknown scale (0–5, 0–100 or 0–255).
        case generic
    }

    /// POPM values written for 1 to 5 stars.
    public static let popmWriteValues = [1: 1, 2: 64, 3: 128, 4: 196, 5: 255]

    /// Stars for a raw value; `nil` means no rating.
    public static func stars(fromRaw raw: Int, scheme: Scheme) -> Int? {
        switch scheme {
        case .popm: starsFromPOPM(raw)
        case .generic: starsFromGeneric(raw)
        }
    }

    /// 0 → none; 1–31 → 1; 32–95 → 2; 96–159 → 3; 160–223 → 4; 224 and above → 5.
    public static func starsFromPOPM(_ raw: Int) -> Int? {
        switch raw {
        case ...0: nil
        case ..<32: 1
        case ..<96: 2
        case ..<160: 3
        case ..<224: 4
        default: 5
        }
    }

    /// 0 → none; 1–5 as is; 6–100 → ⌊(raw + 10) / 20⌋ clamped to 1...5; above 100 → as POPM.
    public static func starsFromGeneric(_ raw: Int) -> Int? {
        switch raw {
        case ...0: nil
        case ...5: raw
        case ...100: min(5, max(1, (raw + 10) / 20))
        default: starsFromPOPM(raw)
        }
    }

    /// POPM byte for 1 to 5 stars; `nil` otherwise.
    public static func popmValue(forStars stars: Int) -> Int? {
        popmWriteValues[stars]
    }
}
