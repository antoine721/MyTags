import Foundation
import MyTagsKit
import Testing

@Suite("Decoding")
struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test("default-config.json decodes completely")
    func defaultConfig() throws {
        let document = try ConfigDocument.decode(from: Repo.data("shared/default-config.json"))
        #expect(document.version == 1)
        #expect(document.fields.map(\.key) == ["genre", "couleur", "pays", "type", "attribut", "note"])
        #expect(document.fieldOptions.count == 24)
        #expect(document.rules.count == 5)
        #expect(document.savedViews.count == 4)
        #expect(document.settings.count == 4)

        let attribut = try #require(document.fields.first { $0.key == "attribut" })
        #expect(attribut.kind == .single)
        #expect(attribut.targetTag == .comment)
        #expect(attribut.targetSlot == 3)
        #expect(!attribut.required)
        #expect(attribut.defaultOptionID == "bc85a049-b586-5c70-a07e-949b93ca0d79")
        let note = try #require(document.fields.first { $0.key == "note" })
        #expect(note.kind == .rating && note.targetTag == .rating && note.isAdvanceTrigger)

        let vert = try #require(document.fieldOptions.first { $0.value == "VERT" })
        #expect(vert.color == "systemGreen")
        #expect(vert.aliases.isEmpty)

        let firstRule = try #require(document.rules.first)
        #expect(firstRule.condition == .titleContains(patterns: ["extended", "extend"]))
        #expect(firstRule.mode == .suggest)
        let genreRule = try #require(document.rules.first { $0.position == 3 })
        #expect(
            genreRule.condition
                == .fieldEquals(
                    fieldID: "d16618ff-069d-50e4-a35e-bd7f4a662907", optionID: "b504918d-a09f-5af7-ba3f-9e7bd2b7d221"))

        let view = try #require(document.savedViews.first)
        #expect(view.filters.specialFilters == [.incomplete])
        #expect(view.sort == LibrarySort(key: .artist, ascending: true))
        #expect(view.skipComplete && view.builtin)

        let formats = try #require(document.settings.first { $0.key == "rating.write_formats" })
        #expect(formats.value == ["mp3", "wav", "aiff"])
    }

    @Test("Track row in API shape")
    func trackRow() throws {
        let json = """
            {"id": "2b0c3f7e-0000-4000-8000-000000000001", "file_path": "/Music/a.mp3", "file_format": "mp3",
             "file_size": 8123456, "file_mtime": "2026-10-01T10:00:00.000Z", "fingerprint": null,
             "title": "Song (Extended Mix)", "artist": "Ninho feat. Jul", "album": "Album", "bpm": 128.5,
             "musical_key": "8A", "duration_ms": 222000, "added_at": "2026-09-01T10:00:00.000Z", "start_ms": 61000,
             "waveform": "AAEC", "audio_key": "audio/x.m4a", "audio_size": 2900000, "cover_key": "covers/x",
             "source_tags": {"GENRE": "Rap Fr", "POPM": 128},
             "baseline": {"genre": "Rap Fr", "grouping": null, "comment": "fr extend sexy", "rating": 3},
             "comment_status": "conforme", "apply_status": "conflit", "apply_message": "GENRE changed",
             "applied_at": null, "updated_at": "2026-10-08T12:00:00.000Z", "deleted_at": null, "rev": 57}
            """
        let track = try decode(Track.self, json)
        #expect(track.fileFormat == "mp3")
        #expect(track.bpm == 128.5)
        #expect(track.baseline == Baseline(genre: "Rap Fr", comment: "fr extend sexy", rating: 3))
        #expect(track.sourceTags?["GENRE"] == "Rap Fr")
        #expect(track.sourceTags?["POPM"]?.intValue == 128)
        #expect(track.commentStatus == .conforme)
        #expect(track.applyStatus == .conflit)
        #expect(track.rev == 57)
        #expect(try roundTrip(track) == track)
    }

    @Test("Minimal and lenient track rows")
    func lenientTrack() throws {
        let track = try decode(
            Track.self,
            #"{"id": "t", "baseline": "{\"genre\": \"POP\", \"rating\": 2}", "apply_status": "nouveau", "comment_status": "?"}"#)
        #expect(track.baseline == Baseline(genre: "POP", rating: 2))
        #expect(track.applyStatus == ApplyStatus(rawValue: "nouveau"))
        #expect(track.commentStatus == nil)
        #expect(track.updatedAt == "")
        let bare = try decode(Track.self, #"{"id": "t2", "file_format": "flac"}"#)
        #expect(bare.applyStatus == .aucun)
        #expect(bare.baseline == nil)
    }

    @Test("Field rows accept 0/1 booleans and defaults")
    func fieldRow() throws {
        let field = try decode(
            Field.self,
            """
            {"id": "f", "key": "pays", "kind": "single", "target_tag": "COMMENT", "target_slot": 1,
             "required": 1, "visible": 0, "artist_level": true, "updated_at": "2026-10-08T00:00:00.000Z"}
            """)
        #expect(field.required)
        #expect(!field.visible)
        #expect(field.artistLevel)
        #expect(!field.isAdvanceTrigger)
        #expect(field.name == "pays")
        #expect(field.position == 0)
        #expect(try roundTrip(field) == field)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Field.self, from: Data(#"{"id": "f", "key": "k", "kind": "date", "target_tag": "GENRE"}"#.utf8))
        }
    }

    @Test("Option rows: aliases as JSON array or JSON text")
    func optionRow() throws {
        let option = try decode(
            FieldOption.self,
            #"{"id": "o", "field_id": "f", "value": "RAP FR", "label": null, "aliases": ["Rap Français"], "archived": false}"#)
        #expect(option.aliases == ["Rap Français"])
        #expect(option.displayLabel == "RAP FR")
        let textual = try decode(
            FieldOption.self, #"{"id": "o", "field_id": "f", "value": "X", "aliases": "[\"Y\"]", "archived": 1}"#)
        #expect(textual.aliases == ["Y"])
        #expect(textual.archived)
        #expect(try roundTrip(option) == option)
    }

    @Test("Track value rows")
    func trackValueRow() throws {
        let row = try decode(
            TrackValue.self,
            """
            {"track_id": "t", "field_id": "f", "option_ids": ["a", "b"], "rating": null, "text_value": null,
             "state": "confirmed", "source": "artist", "updated_at": "2026-10-08T12:00:00.000Z",
             "device_id": "d", "deleted_at": null, "rev": 3}
            """)
        #expect(row.value == FieldValue(optionIDs: ["a", "b"]))
        #expect(row.source == .artist)
        #expect(row.state == .confirmed)
        #expect(try roundTrip(row) == row)
        let rating = try decode(TrackValue.self, #"{"track_id": "t", "field_id": "n", "option_ids": [], "rating": 4}"#)
        #expect(rating.value == FieldValue(rating: 4))
        #expect(rating.source == .user)
    }

    @Test("Rule conditions, including unknown ones")
    func ruleRow() throws {
        let rule = try decode(
            Rule.self,
            """
            {"id": "r", "name": "x", "enabled": 0, "position": 2, "mode": "apply",
             "condition": {"type": "field_equals", "field_id": "f", "option_id": "o"},
             "action": {"field_id": "g", "option_id": "p"}}
            """)
        #expect(!rule.enabled)
        #expect(rule.mode == .apply)
        #expect(rule.condition == .fieldEquals(fieldID: "f", optionID: "o"))
        #expect(rule.action == RuleAction(fieldID: "g", optionID: "p"))
        #expect(try roundTrip(rule) == rule)

        let future = try decode(
            Rule.self,
            #"{"id": "r2", "condition": {"type": "bpm_between", "min": 120}, "action": "{\"field_id\": \"g\", \"option_id\": \"p\"}"}"#
        )
        #expect(future.condition == .unknown(["type": "bpm_between", "min": 120]))
        #expect(future.action.optionID == "p")
        #expect(try roundTrip(future) == future)
    }

    @Test("Saved views with full filters")
    func savedViewRow() throws {
        let view = try decode(
            SavedView.self,
            """
            {"id": "v", "name": "Shatta", "position": 5, "builtin": false, "skip_complete": true,
             "filters": {"fields": {"g": {"options": ["a", "b"], "empty": true}}, "min_rating": 3,
                         "bpm_min": 100, "bpm_max": 130.5, "keys": ["8A"], "statuses": ["envoye"],
                         "special": ["untagged", "future_flag"], "search": "ninho"},
             "sort": {"key": "bpm", "ascending": false}}
            """)
        #expect(view.filters.fields["g"] == FieldFilter(options: ["a", "b"], empty: true))
        #expect(view.filters.minRating == 3)
        #expect(view.filters.bpmMax == 130.5)
        #expect(view.filters.specialFilters == [.untagged])
        #expect(view.sort == LibrarySort(key: .bpm, ascending: false))
        #expect(try roundTrip(view) == view)

        let empty = try decode(SavedView.self, #"{"id": "v", "name": "All", "filters": {}, "sort": {}}"#)
        #expect(empty.filters == LibraryFilter())
        #expect(empty.sort == .default)
    }

    @Test("Filters encode only what is set")
    func filterEncoding() throws {
        let filter = LibraryFilter(special: ["incomplete"])
        let json = try JSONValue(jsonData: JSONEncoder().encode(filter))
        #expect(json == ["special": ["incomplete"]])
    }

    @Test("Settings rows keep any JSON value")
    func settingRow() throws {
        let rows = try decode(
            [SettingRow].self,
            """
            [{"key": "comment.separator", "value": " ", "updated_at": "x", "deleted_at": null},
             {"key": "rating.write_formats", "value": ["mp3"], "updated_at": "x"},
             {"key": "gone", "value": null, "updated_at": "x", "deleted_at": "y"}]
            """)
        #expect(rows[0].value == " ")
        #expect(rows[1].value == ["mp3"])
        #expect(rows[2].value == .null && rows[2].isDeleted)
    }

    @Test("Pending changes encode the push shape with explicit nulls")
    func pendingChange() throws {
        let change = PendingChange(
            id: "c", trackID: "t", fieldID: "f", oldValue: FieldValue(optionIDs: ["a"]), newValue: nil,
            source: .user, createdAt: "2026-10-08T12:00:00.000Z")
        let json = try JSONValue(jsonData: JSONEncoder().encode(change))
        #expect(
            json
                == [
                    "id": "c", "track_id": "t", "field_id": "f",
                    "old_value": ["option_ids": ["a"], "rating": nil, "text": nil],
                    "new_value": nil, "source": "user", "created_at": "2026-10-08T12:00:00.000Z",
                ])
        #expect(try roundTrip(change) == change)
    }

    @Test("JSON values")
    func jsonValue() throws {
        let value = try JSONValue(jsonData: Data(#"{"a": [1, 2.5, true, null, "x"], "b": {}}"#.utf8))
        #expect(value["a"]?.arrayValue == [1, 2.5, true, nil, "x"])
        #expect(value["a"]?.arrayValue?.first?.boolValue == nil)
        #expect(value["a"]?.arrayValue?[2].boolValue == true)
        #expect(value["b"]?.objectValue?.isEmpty == true)
        #expect(try JSONValue(jsonData: value.jsonData()) == value)
        #expect(String(decoding: try JSONValue.number(3).jsonData(), as: UTF8.self) == "3")
    }
}
