import SwiftUI
import CoreData
import UserNotifications

@MainActor
final class HouseholdStore: ObservableObject {
    @Published var records: [HouseholdRecord] = []
    @Published var profile = HouseholdProfile()
    @Published var messages: [ChatMessage] = []
    @Published var error: String?
    @Published var guestSessionActive = false
    @Published var preferences = HouseholdPreferences()
    @Published private(set) var categoryCorrections: [String: Int] = [:]
    @Published private(set) var scope = "guest"
    var onAccountSaved: (() -> Void)?
    private var cloudBaselineOverride: Data?
    var onProfileSaved: (() -> Void)?
    private var applyingCloudProfile = false
    private var snapshots: [String: Snapshot] = [:]
    private var storageAvailable = true
    private let notificationsEnabled: Bool
    private let container: NSPersistentContainer

    init(storageURL: URL? = nil, notificationsEnabled: Bool = true) {
        self.notificationsEnabled = notificationsEnabled
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "LocalSnapshot"
        entity.managedObjectClassName = "NSManagedObject"
        let payload = NSAttributeDescription()
        payload.name = "payload"
        payload.attributeType = .binaryDataAttributeType
        entity.properties = [payload]
        model.entities = [entity]
        container = NSPersistentContainer(name: "HomeMate", managedObjectModel: model)
        if let storageURL { container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: storageURL)] }
        container.persistentStoreDescriptions.forEach { $0.shouldAddStoreAsynchronously = false }
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            storageAvailable = false
            self.error = "Local database could not open: \(loadError.localizedDescription)"
        } else {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: "LocalSnapshot")
                if let data = try container.viewContext.fetch(request).first?.value(forKey: "payload") as? Data {
                    if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
                        guard envelope.version == 2 else { throw CocoaError(.coderReadCorrupt) }
                        snapshots = envelope.accounts
                    } else {
                        // The previous shared snapshot has no verified owner. Keep it in guest storage.
                        snapshots["guest"] = try JSONDecoder().decode(Snapshot.self, from: data)
                    }
                    apply(snapshots["guest"])
                }
            } catch { storageAvailable = false; self.error = "Local data could not be read: \(error.localizedDescription)" }
        }
        #if DEBUG
        // In-memory fixtures for simulator screenshots. Normal launches never use these.
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            profile.name = "Alex"
            profile.household = "Demo Home"
            profile.members = "Alex, Sam, Jamie"
            profile.onboarded = true
            profile.reminders = false
            records = [
                HouseholdRecord(kind: .task, title: "Restock the pantry", date: Date(), category: "Groceries", assignee: "Alex", location: "Colombo grocery errand (preview)", latitude: 6.9271, longitude: 79.8612),
                HouseholdRecord(kind: .task, title: "Water the plants", date: Date(), category: "Home", assignee: "Sam", completed: true),
                HouseholdRecord(kind: .bill, title: "Electricity bill", amount: 8500, date: Date(), category: "Utilities", assignee: "Jamie", important: true),
                HouseholdRecord(kind: .maintenance, title: "AC filter service", date: Date(), category: "Home", assignee: "Sam", notes: "Clean the filters and check the living room unit."),
                HouseholdRecord(kind: .event, title: "Family dinner", date: Date(), assignee: "Everyone", notes: "A little time together at home.", endDate: Date().addingTimeInterval(3600), location: "Home"),
                HouseholdRecord(kind: .expense, title: "Weekly groceries", amount: 6400, category: "Groceries"),
                HouseholdRecord(kind: .expense, title: "Internet", amount: 4200, category: "Utilities")
            ]
        }
        #endif
    }
    private struct Snapshot: Codable {
        var records: [HouseholdRecord]
        var profile: HouseholdProfile
        var messages: [ChatMessage]?
        var preferences: HouseholdPreferences?
        var categoryCorrections: [String: Int]?
        var profilePendingUpload: Bool?
        var cloudBaseline: Data?
    }
    private struct Envelope: Codable { var version = 2; var accounts: [String: Snapshot] }
    static func scope(for userID: String?) -> String { userID.map { "user:" + $0 } ?? "guest" }
    func activate(userID: String?) {
        let next = Self.scope(for: userID)
        guard next != scope else { return }
        scope = next
        apply(snapshots[next])
        if storageAvailable { error = nil }
        if notificationsEnabled {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            scheduleReminders()
        }
    }
    private func apply(_ snapshot: Snapshot?) {
        records = snapshot?.records ?? []
        profile = snapshot?.profile ?? HouseholdProfile()
        messages = snapshot?.messages ?? []
        preferences = snapshot?.preferences ?? HouseholdPreferences()
        categoryCorrections = snapshot?.categoryCorrections ?? [:]
    }
    @discardableResult
    func save() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview") { return true }
        #endif
        guard storageAvailable else { error = "Local storage is unavailable. Your existing data has not been overwritten."; return false }
        if let problem = profile.validationError ?? records.compactMap(\.validationError).first { error = problem; return false }
        guard messages.allSatisfy({ $0.text.count <= 10000 && ($0.photoData?.count ?? 0) <= 10_000_000 && ($0.audioData?.count ?? 0) <= 10_000_000 && ($0.audioFile == nil || $0.audioFile == URL(fileURLWithPath: $0.audioFile!).lastPathComponent) }) else {
            error = "Message is too long or its attachment is invalid."; return false
        }
        guard Set(records.map(\.id)).count == records.count else { error = "Duplicate records cannot be saved."; return false }
        guard preferences.monthlyBudget.isFinite, (0...1_000_000_000_000).contains(preferences.monthlyBudget), preferences.bulletinTitle.count <= 200, preferences.bulletinBody.count <= 10000 else {
            error = "Check your budget and announcement length."; return false
        }
        do {
            var updated = snapshots
            let profileChanged = try Self.profileData(profile) != snapshots[scope].map { try Self.profileData($0.profile) }
            let pending = !applyingCloudProfile && (profileChanged || snapshots[scope]?.profilePendingUpload == true)
            updated[scope] = Snapshot(records: records, profile: profile, messages: messages, preferences: preferences, categoryCorrections: categoryCorrections, profilePendingUpload: pending, cloudBaseline: cloudBaselineOverride ?? snapshots[scope]?.cloudBaseline)
            let request = NSFetchRequest<NSManagedObject>(entityName: "LocalSnapshot")
            let object = try container.viewContext.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "LocalSnapshot", into: container.viewContext)
            object.setValue(try JSONEncoder().encode(Envelope(accounts: updated)), forKey: "payload")
            try container.viewContext.save()
            snapshots = updated
            error = nil
            scheduleReminders()
            if pending { onProfileSaved?() }
            if cloudBaselineOverride == nil { onAccountSaved?() }
            return true
        } catch { container.viewContext.rollback(); self.error = error.localizedDescription; return false }
    }
    var accountSnapshot: AccountSnapshot {
        AccountSnapshot(profile: profile, records: records, messages: messages, preferences: preferences)
    }
    var accountBaseline: AccountSnapshot {
        guard let data = snapshots[scope]?.cloudBaseline,
              let value = try? JSONDecoder().decode(AccountSnapshot.self, from: data) else { return AccountSnapshot() }
        return value
    }
    func migrateVoiceAttachments() throws {
        var updated = messages
        for index in updated.indices where updated[index].audioData == nil {
            guard let filename = updated[index].audioFile else { continue }
            guard filename == URL(fileURLWithPath: filename).lastPathComponent else { throw URLError(.badURL) }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            updated[index].audioData = try Data(contentsOf: directory.appendingPathComponent(filename))
        }
        if try !AccountSnapshot.same(messages, updated), !replaceMessages(updated) {
            throw NSError(domain: "HomeMateSync", code: 1, userInfo: [NSLocalizedDescriptionKey: error ?? "Could not prepare voice notes for sync."])
        }
    }
    /// Preserve edits made during upload, and persist server baseline atomically with restored data.
    func acceptAccountSnapshot(_ remote: AccountSnapshot, sent: AccountSnapshot, expectedScope: String) throws {
        guard scope == expectedScope else { throw CancellationError() }
        let previous = accountSnapshot
        let merged = try AccountSnapshot.merge(local: previous, base: sent, remote: remote)
        cloudBaselineOverride = try remote.encoded()
        applyingCloudProfile = true
        defer { cloudBaselineOverride = nil; applyingCloudProfile = false }
        profile = merged.profile; records = merged.records; messages = merged.messages; preferences = merged.preferences
        guard save() else {
            profile = previous.profile; records = previous.records; messages = previous.messages; preferences = previous.preferences
            throw NSError(domain: "HomeMateSync", code: 2, userInfo: [NSLocalizedDescriptionKey: error ?? "Could not save synced data."])
        }
    }
    static func profileData(_ profile: HouseholdProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(profile)
    }
    var profilePendingUpload: Bool { snapshots[scope]?.profilePendingUpload == true }
    /// Clear the outbox only if the exact uploaded revision is still current.
    func acknowledgeProfile(_ data: Data, expectedScope: String) {
        guard scope == expectedScope, (try? Self.profileData(profile)) == data else { return }
        applyingCloudProfile = true
        defer { applyingCloudProfile = false }
        save()
    }
    func restoreProfile(_ value: HouseholdProfile, expectedScope: String) -> Bool {
        guard scope == expectedScope, !profilePendingUpload else { return false }
        let previous = profile
        applyingCloudProfile = true
        defer { applyingCloudProfile = false }
        profile = value
        if save() { return true }
        profile = previous
        return false
    }
    /// Aggregate only: no titles, OCR text, amounts, record IDs or shared records.
    /// Local account-scoped diagnostics; never uploaded or used to retrain models.
    func recordCategoryCorrection(predicted: String, selected: String, expectedScope: String) {
        guard scope == expectedScope, predicted != selected,
              ExpenseIntelligence.categories.contains(predicted), ExpenseIntelligence.categories.contains(selected) else { return }
        let previous = categoryCorrections
        let key = predicted + " → " + selected
        categoryCorrections[key] = min(1_000_000, (categoryCorrections[key] ?? 0) + 1)
        if !save() { categoryCorrections = previous }
    }
    @discardableResult
    func replaceMessages(_ value: [ChatMessage]) -> Bool {
        let previous = messages
        messages = value
        if save() { return true }
        messages = previous
        return false
    }
    @discardableResult
    func updatePreferences(_ value: HouseholdPreferences) -> Bool {
        let previous = preferences
        preferences = value
        if save() { return true }
        preferences = previous
        return false
    }
    @discardableResult
    func upsert(_ record: HouseholdRecord) -> Bool {
        if let problem = record.validationError { error = problem; return false }
        let previous = records
        var cleaned = record
        cleaned.title = cleaned.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.kind == .bill {
            if cleaned.completed && cleaned.paidAt == nil { cleaned.paidAt = Date() }
            if !cleaned.completed { cleaned.paidAt = nil }
        }
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = cleaned }
        else { records.append(cleaned) }
        if save() { return true }
        records = previous
        return false
    }
    @discardableResult
    func replaceRecords(_ restored: [HouseholdRecord], expectedScope: String) -> Bool {
        guard scope == expectedScope else { return false }
        let previous = records
        records = restored
        if save() { return true }
        records = previous
        return false
    }
    func delete(_ record: HouseholdRecord) {
        let previous = records
        records.removeAll { $0.id == record.id }
        if !save() { records = previous }
    }
    func toggle(_ record: HouseholdRecord) {
        // Apply the action shown by the row to the latest saved record. A stale row
        // must not overwrite edits, reopen an already completed task or revive a deletion.
        guard var current = records.first(where: { $0.id == record.id }), current.completed == record.completed else { return }
        current.completed = !record.completed
        upsert(current)
    }
    var recommendedMember: String {
        profile.memberNames.min { a, b in
            records.filter { !$0.completed && $0.assignee == a && $0.kind != .expense }.count < records.filter { !$0.completed && $0.assignee == b && $0.kind != .expense }.count
        } ?? "Me"
    }
    func money(_ value: Double) -> String { value.formatted(.currency(code: profile.currency)) }
    var monthlyExpenses: [HouseholdRecord] {
        ExpenseIntelligence.spendingRecords(records, inMonthOf: Date())
    }
    func scheduleReminders(for scheduledRecords: [HouseholdRecord]? = nil, identifierPrefix: String? = nil) {
        guard notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard profile.reminders else { return }
        let values = scheduledRecords ?? records
        let prefix = identifierPrefix ?? scope
        for record in values.filter({ !$0.completed && $0.kind != .expense && $0.reminderEnabled != false && $0.date > Date() }).sorted(by: { $0.date < $1.date }).prefix(60) {
            let content = UNMutableNotificationContent()
            content.title = record.title
            content.body = "\(record.kind.rawValue) reminder for \(record.assignee)"
            content.sound = .default
            guard let reminder = ReminderSchedule.date(for: record) else { continue }
            let time = max(1, reminder.timeIntervalSinceNow)
            center.add(UNNotificationRequest(identifier: prefix + ":" + record.id.uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: time, repeats: false)))
        }
    }
    func enableNotifications() async {
        let requestedScope = scope
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard scope == requestedScope else { return }
            profile.reminders = allowed; save()
        }
        catch { self.error = error.localizedDescription }
    }
    func loadExamples() {
        guard records.isEmpty else { return }
        records = [
            HouseholdRecord(kind: .task, title: "Restock the pantry", date: Date().addingTimeInterval(86400), category: "Groceries", assignee: "Me"),
            HouseholdRecord(kind: .bill, title: "Electricity bill", amount: 8500, date: Date().addingTimeInterval(172800), category: "Utilities", important: true),
            HouseholdRecord(kind: .maintenance, title: "Clean the AC filters", date: Date().addingTimeInterval(432000), category: "Home"),
            HouseholdRecord(kind: .expense, title: "Weekly groceries", amount: 6400, category: "Groceries")
        ]; save()
    }
}
