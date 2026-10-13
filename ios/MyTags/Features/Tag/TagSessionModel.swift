import Foundation
import MyTagsKit
import Observation
import UIKit

/// State and actions of the Tag screen (spec 9.2 – 9.3): a frozen queue, one-tap values,
/// validation by rating, 3-second undo, quick pass.
@MainActor
@Observable
final class TagSessionModel {
    enum Mode: Equatable {
        case full
        case quickPass(fieldID: String)
        /// "Actualité" sorting, one swipe per track: left adds the keyword option, right keeps the track.
        case swipe(fieldID: String, optionID: String)
    }

    struct Undo: Equatable {
        let id = UUID()
        let trackID: String
        let index: Int
        let restore: [RestoreEdit]
        let label: String

        static func == (lhs: Undo, rhs: Undo) -> Bool { lhs.id == rhs.id }
    }

    struct RestoreEdit: Sendable {
        let fieldID: String
        let value: FieldValue?
        let source: ValueSource
    }

    @ObservationIgnored unowned let app: AppModel
    private(set) var queue: TagQueue
    private(set) var title: String
    var skipComplete: Bool
    private(set) var mode: Mode = .full
    /// Fields blinking because they are required and empty.
    private(set) var flashing: Set<String> = []
    private(set) var flashGeneration = 0
    private(set) var undo: Undo?
    /// +1 when moving forward, -1 backward (drives the slide transition).
    private(set) var direction = 1
    /// The field whose "add a value" overlay is open.
    var addingValueTo: Field?

    @ObservationIgnored private var undoTimer: Task<Void, Never>?
    @ObservationIgnored private var flashTimer: Task<Void, Never>?
    @ObservationIgnored private var fullQueue: TagQueue?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?
    /// Track whose validation was refused for missing fields: it validates once they are filled.
    @ObservationIgnored private var pendingValidationID: String?
    /// When a validation last moved on: star taps right after it are ignored.
    @ObservationIgnored private var advancedAt: ContinuousClock.Instant?

    /// Session saves run in order, off the main thread.
    private static let saveQueue = DispatchQueue(label: "mytags.session-save", qos: .utility)

    init(app: AppModel, queue: TagQueue, title: String, skipComplete: Bool) {
        self.app = app
        self.queue = queue
        self.title = title
        self.skipComplete = skipComplete
    }

    var store: LibraryStore { app.store }
    var config: TagConfig { store.config }

    var currentTrack: Track? {
        queue.currentTrackID.flatMap { store.tracks[$0] }
    }

    /// Effective values of the current track (re-evaluated when the store changes).
    var resolved: ResolvedTrack? {
        _ = store.dataVersion
        return queue.currentTrackID.flatMap { store.resolve($0) }
    }

    var positionText: String {
        guard let position = queue.displayPosition else { return "\(queue.count) / \(queue.count)" }
        return "\(position.formatted()) / \(queue.count.formatted())"
    }

    // MARK: Lifecycle

    func begin(autoplay: Bool) {
        let player = app.player
        player.onNext = { [weak self] in self?.next() }
        player.onPrevious = { [weak self] in self?.previous() }
        player.onUnavailable = { [weak self] id in self?.handleUnavailable(id) }
        player.onPlayStarted = { [weak self] _ in self?.app.sessions.activity() }
        observeBackground()
        if skipComplete, let id = queue.currentTrackID, store.snapshots[id]?.isIncomplete == false {
            queue.next(where: isWanted)
        }
        show(autoplay: autoplay)
    }

    /// Called when the Tag screen opens again from the mini player, after `end()`.
    func reopen() {
        observeBackground()
    }

    /// Flushes the delayed session save when the app leaves (it may not run again before a kill).
    private func observeBackground() {
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.saveTask != nil { self?.saveNow(waiting: true) }
            }
        }
    }

    /// Called when the Tag screen closes: stores the session and shows the summary if relevant.
    func end() {
        let previous = app.sessions.history(limit: 1).first
        if let record = app.sessions.end(), record.validatedCount >= 5 {
            app.sessionSummary = SessionSummary(current: record, previous: previous)
        }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        saveTask?.cancel()
        saveTask = nil
        // After the saves already queued, so none of them brings the closed session back.
        Self.save(nil, to: app.database, waiting: true)
    }

    private func show(autoplay: Bool) {
        guard let track = currentTrack else {
            app.player.pause()
            persist()
            return
        }
        app.player.load(track, autoplay: autoplay)
        app.prefetcher.update(queue: queue)
        if let nextID = queue.trackIDs[safe: queue.currentIndex + 1] {
            app.player.prepare(store.tracks[nextID])
        }
        app.sessions.beginTrack(track.id)
        pendingValidationID = nil
        persist()
    }

    /// Saves the session for the next launch (spec 9.1) shortly after the last move: encoding a
    /// queue of 5,000 ids at every track change would slow it down. Flushed when the app leaves.
    private func persist() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow(waiting: false)
        }
    }

    private func saveNow(waiting: Bool) {
        saveTask?.cancel()
        saveTask = nil
        Self.save(SavedSession(queue: queue, title: title, skipComplete: skipComplete), to: app.database, waiting: waiting)
    }

    private static func save(_ session: SavedSession?, to database: AppDatabase, waiting: Bool) {
        let work = { @Sendable in Self.write(session, to: database) }
        if waiting { saveQueue.sync(execute: work) } else { saveQueue.async(execute: work) }
    }

    private nonisolated static func write(_ session: SavedSession?, to database: AppDatabase) {
        database.setValue(session, forKey: SavedSession.key)
    }

    // MARK: Navigation

    private func isWanted(_ id: String) -> Bool {
        if skipComplete, store.snapshots[id]?.isIncomplete == false { return false }
        if case let .quickPass(fieldID) = mode, store.snapshots[id]?.confirmedFieldIDs.contains(fieldID) == true {
            return false
        }
        if case let .swipe(fieldID, _) = mode, isDecided(id, fieldID: fieldID) { return false }
        if !app.sync.isOnline, app.settings.skipUnavailableOffline, !app.cache.offlineIDs.contains(id) { return false }
        return true
    }

    func next(autoplay: Bool? = nil) {
        guard !queue.isAtEnd else { return }
        let play = autoplay ?? app.player.isPlaying
        direction = 1
        queue.next(where: isWanted)
        show(autoplay: play)
    }

    /// Always the previous track of the queue, never the start of the current one.
    func previous() {
        guard queue.hasPrevious else { return }
        let play = app.player.isPlaying
        direction = -1
        queue.previous()
        show(autoplay: play)
    }

    func jump(to index: Int, autoplay: Bool) {
        direction = index >= queue.currentIndex ? 1 : -1
        queue.move(to: index)
        show(autoplay: autoplay)
    }

    private func handleUnavailable(_ id: String) {
        guard id == queue.currentTrackID, app.settings.skipUnavailableOffline, !app.sync.isOnline else { return }
        next(autoplay: true)
    }

    /// Switches to another queue without closing the screen (header menu, end of queue).
    func replaceQueue(with ids: [String], title: String, skipComplete: Bool) {
        guard !ids.isEmpty else { return }
        queue = TagQueue(trackIDs: ids)
        self.title = title
        self.skipComplete = skipComplete
        mode = .full
        fullQueue = nil
        if skipComplete, let id = queue.currentTrackID, store.snapshots[id]?.isIncomplete == false {
            queue.next(where: isWanted)
        }
        show(autoplay: app.player.isPlaying)
    }

    // MARK: Values

    func tap(option: FieldOption, in field: Field) {
        guard let trackID = queue.currentTrackID else { return }
        select(option: option, in: field, trackID: trackID)
    }

    private func select(option: FieldOption, in field: Field, trackID: String) {
        guard let resolved = store.resolve(trackID) else { return }
        app.sessions.tap()
        let current = resolved[field.id]
        let edit: ValueEdit
        if field.kind == .multi {
            if current?.state == .suggested, current?.value.optionIDs.contains(option.id) == true {
                edit = ValueEdit(trackID: trackID, fieldID: field.id, value: current!.value, source: current?.source ?? .user)
            } else {
                var ids = current?.state == .confirmed ? current!.value.optionIDs : []
                if let index = ids.firstIndex(of: option.id) { ids.remove(at: index) } else { ids.append(option.id) }
                edit = ValueEdit(
                    trackID: trackID, fieldID: field.id,
                    value: FieldValue(optionIDs: config.sortedOptionIDs(ids, forField: field.id)), source: .user)
            }
        } else if current?.state == .confirmed, current?.value.optionIDs == [option.id] {
            edit = ValueEdit(trackID: trackID, fieldID: field.id, value: FieldValue(), source: .user)
        } else if current?.state == .suggested, current?.value.optionIDs.contains(option.id) == true {
            edit = ValueEdit(trackID: trackID, fieldID: field.id, value: current!.value, source: current?.source ?? .user)
        } else {
            edit = ValueEdit(trackID: trackID, fieldID: field.id, value: .option(option.id), source: .user)
        }
        if edit.source == .user { app.sessions.manualValue() }
        commit([edit])
        Haptics.shared.select()
        validateIfPending(trackID)
    }

    func rate(_ stars: Int, field: Field) {
        // The second tap of a double tap must not rate the track that just appeared.
        if let advancedAt, ContinuousClock.now - advancedAt < .milliseconds(300) { return }
        guard let track = currentTrack else { return }
        app.sessions.tap()
        commit([ValueEdit(trackID: track.id, fieldID: field.id, value: .stars(stars), source: .user)])
        if field.isAdvanceTrigger {
            validate()
        } else {
            Haptics.shared.select()
        }
    }

    func clearRating(field: Field) {
        guard let track = currentTrack else { return }
        pendingValidationID = nil
        app.sessions.tap()
        commit([ValueEdit(trackID: track.id, fieldID: field.id, value: FieldValue(), source: .user)])
        Haptics.shared.select()
    }

    func setText(_ text: String, field: Field) {
        guard let track = currentTrack else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        commit([ValueEdit(trackID: track.id, fieldID: field.id, value: FieldValue(text: trimmed.isEmpty ? nil : trimmed),
                          source: .user)])
        validateIfPending(track.id)
    }

    /// Writes edits (all on one track), then the values of "apply" rules that this action made true.
    private func commit(_ edits: [ValueEdit]) {
        guard store.apply(edits) else {
            Haptics.shared.error()
            return
        }
        guard let trackID = edits.first?.trackID, let after = store.resolve(trackID) else { return }
        let ruleEdits = after.applyModeRuleValues
            .filter { after[$0.key]?.hasRow == false }
            .map { ValueEdit(trackID: trackID, fieldID: $0.key, value: $0.value, source: .rule) }
        if !ruleEdits.isEmpty { store.apply(ruleEdits) }
    }

    // MARK: Validation

    /// Confirms every suggestion and moves on, or flashes the missing required fields.
    func validate() {
        guard let track = currentTrack, let resolved else { return }
        let missing = Completeness.missingRequiredFields(resolved, config: config)
        guard missing.isEmpty else {
            pendingValidationID = track.id
            flash(Set(missing))
            Haptics.shared.error()
            return
        }
        pendingValidationID = nil
        let plan = ValidationPlan.make(resolved: resolved, config: config)
        let restore = plan.values.map { planned -> RestoreEdit in
            if let row = store.rows[track.id]?[planned.fieldID], !row.isDeleted {
                return RestoreEdit(fieldID: planned.fieldID, value: row.value, source: row.source)
            }
            return RestoreEdit(fieldID: planned.fieldID, value: nil, source: .file)
        }
        let edits = plan.values.map { ValueEdit(trackID: track.id, fieldID: $0.fieldID, value: $0.value, source: $0.source) }
        guard store.apply(edits) else {
            Haptics.shared.error()
            return
        }
        app.sessions.validated(accepted: plan.values.filter { $0.source.isSuggestionSource }.count, manual: 0)
        Haptics.shared.success()
        let index = queue.currentIndex
        if app.settings.autoAdvance {
            advancedAt = .now
            next(autoplay: true)
        }
        showUndo(Undo(trackID: track.id, index: index, restore: restore, label: "Validé"))
    }

    /// After a refused validation, the track validates itself as soon as its last missing required
    /// field gets a value (the rating is already stored); the undo banner still comes back to it.
    private func validateIfPending(_ trackID: String) {
        guard pendingValidationID == trackID, queue.currentTrackID == trackID, let resolved,
              Completeness.missingRequiredFields(resolved, config: config).isEmpty
        else { return }
        validate()
    }

    private func flash(_ fields: Set<String>) {
        flashing = fields
        flashGeneration += 1
        flashTimer?.cancel()
        flashTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            self?.flashing = []
        }
    }

    // MARK: Undo

    /// 3 seconds (spec B-14); longer with VoiceOver, which needs time to reach the button.
    static var undoDuration: Duration {
        if ProcessInfo.processInfo.arguments.contains("-uitest-demo") { return .seconds(30) }
        return UIAccessibility.isVoiceOverRunning ? .seconds(10) : .seconds(3)
    }

    private func showUndo(_ value: Undo) {
        undo = value
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.undoDuration)
            guard !Task.isCancelled else { return }
            self?.undo = nil
        }
    }

    func performUndo() {
        guard let undo else { return }
        undoTimer?.cancel()
        self.undo = nil
        let edits = undo.restore.map { ValueEdit(trackID: undo.trackID, fieldID: $0.fieldID, value: $0.value, source: $0.source) }
        store.apply(edits)
        Haptics.shared.undo()
        if queue.currentTrackID != undo.trackID {
            direction = -1
            queue.move(to: undo.index)
            show(autoplay: app.player.isPlaying)
        }
    }

    // MARK: Quick pass (spec 9.3)

    func startQuickPass(fieldID: String) {
        fullQueue = fullQueue ?? queue
        let remaining = Array(queue.trackIDs[min(queue.currentIndex, queue.count)...])
        let ids = remaining.filter { store.snapshots[$0]?.confirmedFieldIDs.contains(fieldID) != true }
        mode = .quickPass(fieldID: fieldID)
        queue = TagQueue(trackIDs: ids)
        show(autoplay: app.player.isPlaying)
    }

    /// Leaves the quick pass or the swipe mode, back on the full queue at the current track.
    func stopQuickPass() {
        guard mode != .full else { return }
        mode = .full
        if let fullQueue, let id = queue.currentTrackID ?? fullQueue.currentTrackID {
            var restored = fullQueue
            if let index = restored.index(of: id) { restored.move(to: index) }
            queue = restored
        }
        fullQueue = nil
        show(autoplay: app.player.isPlaying)
    }

    /// One tap: confirms the value and moves on immediately, with the undo banner.
    func quickPick(option: FieldOption, field: Field) {
        guard let track = currentTrack else { return }
        app.sessions.tap()
        let previous = store.rows[track.id]?[field.id]
        let restore = [RestoreEdit(
            fieldID: field.id, value: previous?.isDeleted == false ? previous?.value : nil,
            source: previous?.isDeleted == false ? previous!.source : .file)]
        guard store.apply([ValueEdit(trackID: track.id, fieldID: field.id, value: .option(option.id), source: .user)]) else {
            Haptics.shared.error()
            return
        }
        app.sessions.validated(accepted: 0, manual: 1)
        Haptics.shared.success()
        let index = queue.currentIndex
        next(autoplay: true)
        showUndo(Undo(trackID: track.id, index: index, restore: restore, label: option.displayLabel))
    }

    // MARK: Swipe ("Actualité")

    /// Swipe mode on the rest of the queue: only tracks never sorted (no value, not even cleared).
    /// `showing: false` before `begin(autoplay:)`, which loads the first track itself.
    func startSwipe(field: Field, option: FieldOption, showing: Bool = true) {
        fullQueue = fullQueue ?? queue
        let remaining = Array(queue.trackIDs[min(queue.currentIndex, queue.count)...])
        mode = .swipe(fieldID: field.id, optionID: option.id)
        queue = TagQueue(trackIDs: remaining.filter { !isDecided($0, fieldID: field.id) })
        if showing { show(autoplay: app.player.isPlaying) }
    }

    /// A confirmed value or a row, even an empty one ("d'actualité"), means the track was sorted.
    private func isDecided(_ id: String, fieldID: String) -> Bool {
        if store.snapshots[id]?.confirmedFieldIDs.contains(fieldID) == true { return true }
        if let row = store.rows[id]?[fieldID], !row.isDeleted { return true }
        return false
    }

    /// Left: the keyword option ("ARCHIVE"); right: an empty value, the track stays current.
    func swipe(archive: Bool) {
        guard case let .swipe(fieldID, optionID) = mode, let track = currentTrack else { return }
        app.sessions.tap()
        let previous = store.rows[track.id]?[fieldID]
        let restore = [RestoreEdit(
            fieldID: fieldID, value: previous?.isDeleted == false ? previous?.value : nil,
            source: previous?.isDeleted == false ? previous!.source : .file)]
        let value = archive ? FieldValue.option(optionID) : FieldValue()
        guard store.apply([ValueEdit(trackID: track.id, fieldID: fieldID, value: value, source: .user)]) else {
            Haptics.shared.error()
            return
        }
        app.sessions.validated(accepted: 0, manual: 1)
        Haptics.shared.success()
        let index = queue.currentIndex
        next(autoplay: true)
        showUndo(Undo(trackID: track.id, index: index, restore: restore, label: archive ? "Archivé" : "D'actualité"))
    }

    // MARK: New values (B-16)

    /// Creates a value for `field` and selects it on the current track.
    func addOption(_ text: String, to field: Field) async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // The track on screen now: it may change while the value is being saved.
        guard !value.isEmpty, let trackID = queue.currentTrackID else { return }
        if let existing = config.option(fieldID: field.id, value: value) {
            select(option: existing, in: field, trackID: trackID)
            return
        }
        let position = (config.options(forField: field.id).map(\.position).max() ?? -1) + 1
        let option = FieldOption(
            id: UUID().uuidString.lowercased(), fieldID: field.id, value: value, label: value, position: position,
            updatedAt: Timestamp.string(from: Date()))
        await store.saveConfig(DirtyConfig(fieldOptions: [option]))
        if let saved = store.config.option(id: option.id) {
            select(option: saved, in: field, trackID: trackID)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// End-of-session recap (spec 9.10).
struct SessionSummary: Identifiable, Sendable {
    let current: SessionRecord
    let previous: SessionRecord?
    var id: String { current.id }
}
