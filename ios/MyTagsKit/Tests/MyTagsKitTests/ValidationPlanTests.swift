import Foundation
import MyTagsKit
import Testing

@Suite("Validation plan")
struct ValidationPlanTests {
    let config = Fixtures.config

    @Test("Suggestions and file values of fields without a row, with their source")
    func plan() {
        let track = Fixtures.track("t", title: "Song (Extended)", genre: "rap fr", comment: "fr", rating: 3)
        let rows = [Fixtures.row("t", "couleur", ["VERT"]), Fixtures.row("t", "note", rating: 4)]
        let resolved = ValueResolver.resolve(track: track, rows: rows, config: config, suggestionContext: SuggestionContext())
        let plan = ValidationPlan.make(resolved: resolved, config: config)
        #expect(
            plan.values == [
                PlannedValue(fieldID: Fixtures.fieldID("genre"), value: .option(Fixtures.optionID("genre", "RAP FR")), source: .file),
                PlannedValue(fieldID: Fixtures.fieldID("pays"), value: .option(Fixtures.optionID("pays", "FR")), source: .file),
                PlannedValue(fieldID: Fixtures.fieldID("type"), value: .option(Fixtures.optionID("type", "EXTEND")), source: .title),
                PlannedValue(fieldID: Fixtures.fieldID("attribut"), value: .option(Fixtures.optionID("attribut", "()")), source: .default),
            ])
        #expect(!plan.isEmpty)
    }

    @Test("Validating normalises the file tags (decision 0005, point 4)")
    func normalisation() {
        let track = Fixtures.track("t", genre: "Rap Fr", grouping: "vert", comment: "fr extend sexy", rating: 4)
        let resolved = ValueResolver.resolve(track: track, rows: [], config: config, suggestionContext: SuggestionContext())
        #expect(!resolved.isToApply(config: config))
        let plan = ValidationPlan.make(resolved: resolved, config: config)
        #expect(plan.values.allSatisfy { $0.source == .file })
        let rows = plan.values.map { TrackValue(trackID: "t", fieldID: $0.fieldID, value: $0.value, source: $0.source) }
        let validated = ValueResolver.resolve(track: track, rows: rows, config: config, suggestionContext: SuggestionContext())
        #expect(validated.targets(config: config) == Baseline(genre: "RAP FR", grouping: "VERT", comment: "FR EXTEND SEXY", rating: 4))
        #expect(validated.isToApply(config: config))
        #expect(ValidationPlan.make(resolved: validated, config: config).isEmpty)
    }

    @Test("Plan as journal entries")
    func pendingChanges() {
        let resolved = ValueResolver.resolve(
            track: Fixtures.track("t", genre: "POP"), rows: [], config: config, suggestionContext: nil)
        var counter = 0
        let changes = ValidationPlan.make(resolved: resolved, config: config)
            .pendingChanges(trackID: "t", createdAt: "2026-10-08T12:00:00.000Z") {
                counter += 1
                return "c\(counter)"
            }
        #expect(
            changes == [
                PendingChange(
                    id: "c1", trackID: "t", fieldID: Fixtures.fieldID("genre"), oldValue: nil,
                    newValue: .option(Fixtures.optionID("genre", "POP")), source: .file,
                    createdAt: "2026-10-08T12:00:00.000Z")
            ])
    }
}
