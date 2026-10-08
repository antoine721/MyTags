import Foundation
import MyTagsKit
import Testing

@Suite("Rating scales")
struct RatingScaleTests {
    @Test("Shared vectors: rating_read", arguments: Vectors.ratingRead)
    func read(_ vector: RatingCase) throws {
        let scheme = try #require(RatingScale.Scheme(rawValue: vector.scheme))
        #expect(RatingScale.stars(fromRaw: vector.raw, scheme: scheme) == vector.stars)
    }

    @Test("Shared vectors: popm_write")
    func write() throws {
        let vectors = try #require(Vectors.shared)
        #expect(!vectors.popm_write.isEmpty)
        for (stars, raw) in vectors.popm_write {
            let value = try #require(Int(stars))
            #expect(RatingScale.popmValue(forStars: value) == raw)
        }
    }

    @Test("Out of range values")
    func outOfRange() {
        #expect(RatingScale.starsFromPOPM(-3) == nil)
        #expect(RatingScale.starsFromPOPM(300) == 5)
        #expect(RatingScale.starsFromGeneric(6) == 1)
        #expect(RatingScale.starsFromGeneric(99) == 5)
        #expect(RatingScale.popmValue(forStars: 0) == nil)
        #expect(RatingScale.popmValue(forStars: 6) == nil)
        for stars in 1...5 {
            let raw = RatingScale.popmValue(forStars: stars) ?? -1
            #expect(RatingScale.starsFromPOPM(raw) == stars)
        }
    }
}
