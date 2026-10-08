import Foundation
import MyTagsKit
import Testing

@Suite("Primary artist")
struct ArtistNameTests {
    @Test("Shared vectors: primary_artist", arguments: Vectors.primaryArtist)
    func vector(_ vector: ArtistCase) {
        #expect(ArtistName.primary(vector.artist) == vector.primary)
    }

    @Test("Shared vectors load")
    func vectorsLoad() {
        #expect(!Vectors.primaryArtist.isEmpty)
    }

    @Test("Earliest separator wins; trimming happens first")
    func edgeCases() {
        #expect(ArtistName.primary("A, B feat. C") == "A")
        #expect(ArtistName.primary("Ninho FEAT. Jul") == "Ninho")
        #expect(ArtistName.primary("Ninho feat. ") == "Ninho feat.")
        #expect(ArtistName.primary(" & Jul") == "& Jul")
        #expect(ArtistName.primary(nil) == "")
        #expect(ArtistName.primary("Booba VS Kaaris") == "Booba")
    }

    @Test("Grouping key")
    func key() {
        #expect(ArtistName.key("Ninho feat. Jul") == "NINHO")
        #expect(ArtistName.key("  ninho ") == "NINHO")
        #expect(ArtistName.key(nil) == "")
    }
}
