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
        let account = Self.entity("LocalAccount", [
            Self.attribute("scope", .stringAttributeType, optional: false, default: "guest"),
            Self.attribute("profileData", .binaryDataAttributeType), Self.attribute("preferencesData", .binaryDataAttributeType),
            Self.attribute("correctionsData", .binaryDataAttributeType),
            Self.attribute("profilePendingUpload", .booleanAttributeType, optional: false, default: false),
            Self.attribute("cloudBaseline", .binaryDataAttributeType)
        ])
        let record = Self.entity("LocalRecord", [
            Self.attribute("id", .stringAttributeType, optional: false), Self.attribute("scope", .stringAttributeType, optional: false),
            Self.attribute("sortIndex", .integer64AttributeType, optional: false, default: 0),
            Self.attribute("kind", .stringAttributeType, optional: false), Self.attribute("title", .stringAttributeType, optional: false),
            Self.attribute("amount", .doubleAttributeType, optional: false, default: 0.0), Self.attribute("date", .dateAttributeType, optional: false, default: Date(timeIntervalSince1970: 0)),
            Self.attribute("category", .stringAttributeType, optional: false, default: "Other"), Self.attribute("assignee", .stringAttributeType, optional: false, default: "Me"),
            Self.attribute("important", .booleanAttributeType, optional: false, default: false), Self.attribute("completed", .booleanAttributeType, optional: false, default: false),
            Self.attribute("referenceNumber", .stringAttributeType), Self.attribute("notes", .stringAttributeType, optional: false, default: ""),
            Self.attribute("endDate", .dateAttributeType), Self.attribute("location", .stringAttributeType), Self.attribute("contactPhone", .stringAttributeType),
            Self.attribute("paidAt", .dateAttributeType), Self.attribute("cloudRevision", .stringAttributeType),
            Self.attribute("latitude", .doubleAttributeType), Self.attribute("longitude", .doubleAttributeType),
            Self.attribute("reminderEnabled", .booleanAttributeType), Self.attribute("reminderDate", .dateAttributeType)
        ])
        let message = Self.entity("LocalMessage", [
            Self.attribute("id", .stringAttributeType, optional: false), Self.attribute("scope", .stringAttributeType, optional: false),
            Self.attribute("sortIndex", .integer64AttributeType, optional: false, default: 0),
            Self.attribute("author", .stringAttributeType, optional: false), Self.attribute("text", .stringAttributeType, optional: false),
            Self.attribute("date", .dateAttributeType, optional: false, default: Date(timeIntervalSince1970: 0)),
            Self.attribute("isMine", .booleanAttributeType, optional: false, default: true), Self.attribute("isSample", .booleanAttributeType, optional: false, default: false),
            Self.attribute("photoData", .binaryDataAttributeType, external: true), Self.attribute("audioFile", .stringAttributeType),
            Self.attribute("audioData", .binaryDataAttributeType, external: true), Self.attribute("recordID", .stringAttributeType),
            Self.attribute("replyPreview", .stringAttributeType), Self.attribute("reaction", .stringAttributeType)
        ])
        model.entities = [entity, account, record, message]
        container = NSPersistentContainer(name: "HomeMate", managedObjectModel: model)
        if let storageURL { container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: storageURL)] }
        container.persistentStoreDescriptions.forEach { description in
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            storageAvailable = false
            self.error = "Local database could not open: \(loadError.localizedDescription)"
        } else {
            do {
                try loadManagedSnapshots()
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
    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = true, default defaultValue: Any? = nil, external: Bool = false) -> NSAttributeDescription {
        let value = NSAttributeDescription()
        value.name = name; value.attributeType = type; value.isOptional = optional; value.defaultValue = defaultValue
        value.allowsExternalBinaryDataStorage = external
        return value
    }
    private static func entity(_ name: String, _ attributes: [NSAttributeDescription]) -> NSEntityDescription {
        let value = NSEntityDescription()
        value.name = name; value.managedObjectClassName = "NSManagedObject"; value.properties = attributes
        return value
    }
    private func loadManagedSnapshots() throws {
        let context = container.viewContext
        let accounts = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "LocalAccount"))
        for account in accounts {
            guard let scope = account.value(forKey: "scope") as? String else { throw CocoaError(.coderReadCorrupt) }
            let records = NSFetchRequest<NSManagedObject>(entityName: "LocalRecord")
            records.predicate = NSPredicate(format: "scope == %@", scope)
            records.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
            let messages = NSFetchRequest<NSManagedObject>(entityName: "LocalMessage")
            messages.predicate = NSPredicate(format: "scope == %@", scope)
            messages.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
            snapshots[scope] = Snapshot(
                records: try context.fetch(records).map(decodeRecord),
                profile: try Self.decode(HouseholdProfile.self, account.value(forKey: "profileData")) ?? HouseholdProfile(),
                messages: try context.fetch(messages).map(decodeMessage),
                preferences: try Self.decode(HouseholdPreferences.self, account.value(forKey: "preferencesData")) ?? HouseholdPreferences(),
                categoryCorrections: try Self.decode([String: Int].self, account.value(forKey: "correctionsData")) ?? [:],
                profilePendingUpload: (account.value(forKey: "profilePendingUpload") as? Bool) ?? false,
                cloudBaseline: account.value(forKey: "cloudBaseline") as? Data
            )
        }
        // Retry any import interrupted after some account scopes were already copied.
        try migrateLegacySnapshotIfPresent()
        apply(snapshots["guest"])
    }
    private static func decode<Value: Decodable>(_ type: Value.Type, _ value: Any?) throws -> Value? {
        guard let data = value as? Data else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    private func migrateLegacySnapshotIfPresent() throws {
        let context = container.viewContext
        let legacy = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "LocalSnapshot"))
        guard let data = legacy.first?.value(forKey: "payload") as? Data else { return }
        let oldSnapshots: [String: Snapshot]
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            guard envelope.version == 2 else { throw CocoaError(.coderReadCorrupt) }
            oldSnapshots = envelope.accounts
        } else {
            // Unscoped historical data has no verified owner; keep it in guest storage.
            oldSnapshots = ["guest": try JSONDecoder().decode(Snapshot.self, from: data)]
        }
        for (scope, snapshot) in oldSnapshots where snapshots[scope] == nil {
            try persist(snapshot, scope: scope)
            snapshots[scope] = snapshot
        }
        // The old row is removed only after every missing scope has been saved.
        legacy.forEach(context.delete)
        try context.save()
    }
    private func persist(_ snapshot: Snapshot, scope: String) throws {
        let context = container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "LocalAccount")
        request.predicate = NSPredicate(format: "scope == %@", scope); request.fetchLimit = 1
        let account = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "LocalAccount", into: context)
        account.setValue(scope, forKey: "scope")
        account.setValue(try JSONEncoder().encode(snapshot.profile), forKey: "profileData")
        account.setValue(try JSONEncoder().encode(snapshot.preferences ?? HouseholdPreferences()), forKey: "preferencesData")
        account.setValue(try JSONEncoder().encode(snapshot.categoryCorrections ?? [:]), forKey: "correctionsData")
        account.setValue(snapshot.profilePendingUpload ?? false, forKey: "profilePendingUpload")
        account.setValue(snapshot.cloudBaseline, forKey: "cloudBaseline")
        try persistRecords(snapshot.records, scope: scope, context: context)
        try persistMessages(snapshot.messages ?? [], scope: scope, context: context)
        try context.save()
    }
    private func rows(_ entity: String, scope: String, context: NSManagedObjectContext) throws -> [String: NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "scope == %@", scope)
        var result: [String: NSManagedObject] = [:]
        for object in try context.fetch(request) {
            guard let id = object.value(forKey: "id") as? String else { continue }
            if result[id] == nil { result[id] = object } else { context.delete(object) }
        }
        return result
    }
    private func persistRecords(_ records: [HouseholdRecord], scope: String, context: NSManagedObjectContext) throws {
        var old = try rows("LocalRecord", scope: scope, context: context)
        for (index, record) in records.enumerated() {
            let object = old.removeValue(forKey: record.id.uuidString) ?? NSEntityDescription.insertNewObject(forEntityName: "LocalRecord", into: context)
            object.setValue(record.id.uuidString, forKey: "id"); object.setValue(scope, forKey: "scope"); object.setValue(Int64(index), forKey: "sortIndex")
            object.setValue(record.kind.rawValue, forKey: "kind"); object.setValue(record.title, forKey: "title")
            object.setValue(record.amount, forKey: "amount"); object.setValue(record.date, forKey: "date")
            object.setValue(record.category, forKey: "category"); object.setValue(record.assignee, forKey: "assignee")
            object.setValue(record.important, forKey: "important"); object.setValue(record.completed, forKey: "completed")
            object.setValue(record.referenceNumber, forKey: "referenceNumber"); object.setValue(record.notes, forKey: "notes")
            object.setValue(record.endDate, forKey: "endDate"); object.setValue(record.location, forKey: "location")
            object.setValue(record.contactPhone, forKey: "contactPhone"); object.setValue(record.paidAt, forKey: "paidAt")
            object.setValue(record.cloudRevision, forKey: "cloudRevision"); object.setValue(record.latitude, forKey: "latitude")
            object.setValue(record.longitude, forKey: "longitude"); object.setValue(record.reminderEnabled, forKey: "reminderEnabled")
            object.setValue(record.reminderDate, forKey: "reminderDate")
        }
        old.values.forEach(context.delete)
    }
    private func persistMessages(_ messages: [ChatMessage], scope: String, context: NSManagedObjectContext) throws {
        var old = try rows("LocalMessage", scope: scope, context: context)
        for (index, message) in messages.enumerated() {
            let object = old.removeValue(forKey: message.id.uuidString) ?? NSEntityDescription.insertNewObject(forEntityName: "LocalMessage", into: context)
            object.setValue(message.id.uuidString, forKey: "id"); object.setValue(scope, forKey: "scope"); object.setValue(Int64(index), forKey: "sortIndex")
            object.setValue(message.author, forKey: "author"); object.setValue(message.text, forKey: "text"); object.setValue(message.date, forKey: "date")
            object.setValue(message.isMine, forKey: "isMine"); object.setValue(message.isSample, forKey: "isSample")
            object.setValue(message.photoData, forKey: "photoData"); object.setValue(message.audioFile, forKey: "audioFile")
            object.setValue(message.audioData, forKey: "audioData"); object.setValue(message.recordID?.uuidString, forKey: "recordID")
            object.setValue(message.replyPreview, forKey: "replyPreview"); object.setValue(message.reaction, forKey: "reaction")
        }
        old.values.forEach(context.delete)
    }
    private func decodeRecord(_ object: NSManagedObject) throws -> HouseholdRecord {
        guard let id = (object.value(forKey: "id") as? String).flatMap(UUID.init(uuidString:)),
              let kindRaw = object.value(forKey: "kind") as? String, let kind = RecordKind(rawValue: kindRaw),
              let title = object.value(forKey: "title") as? String, let date = object.value(forKey: "date") as? Date else { throw CocoaError(.coderReadCorrupt) }
        return HouseholdRecord(id: id, kind: kind, title: title, amount: (object.value(forKey: "amount") as? Double) ?? 0, date: date,
            category: (object.value(forKey: "category") as? String) ?? "Other", assignee: (object.value(forKey: "assignee") as? String) ?? "Me",
            important: (object.value(forKey: "important") as? Bool) ?? false, completed: (object.value(forKey: "completed") as? Bool) ?? false,
            referenceNumber: object.value(forKey: "referenceNumber") as? String, notes: (object.value(forKey: "notes") as? String) ?? "",
            endDate: object.value(forKey: "endDate") as? Date, location: object.value(forKey: "location") as? String,
            contactPhone: object.value(forKey: "contactPhone") as? String, paidAt: object.value(forKey: "paidAt") as? Date,
            cloudRevision: object.value(forKey: "cloudRevision") as? String, latitude: (object.value(forKey: "latitude") as? NSNumber)?.doubleValue,
            longitude: (object.value(forKey: "longitude") as? NSNumber)?.doubleValue, reminderEnabled: object.value(forKey: "reminderEnabled") as? Bool,
            reminderDate: object.value(forKey: "reminderDate") as? Date)
    }
    private func decodeMessage(_ object: NSManagedObject) throws -> ChatMessage {
        guard let id = (object.value(forKey: "id") as? String).flatMap(UUID.init(uuidString:)),
              let author = object.value(forKey: "author") as? String, let text = object.value(forKey: "text") as? String,
              let date = object.value(forKey: "date") as? Date else { throw CocoaError(.coderReadCorrupt) }
        return ChatMessage(id: id, author: author, text: text, date: date,
            isMine: (object.value(forKey: "isMine") as? Bool) ?? true, isSample: (object.value(forKey: "isSample") as? Bool) ?? false,
            photoData: object.value(forKey: "photoData") as? Data, audioFile: object.value(forKey: "audioFile") as? String,
            audioData: object.value(forKey: "audioData") as? Data, recordID: (object.value(forKey: "recordID") as? String).flatMap(UUID.init(uuidString:)),
            replyPreview: object.value(forKey: "replyPreview") as? String, reaction: object.value(forKey: "reaction") as? String)
    }
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
        guard Set(messages.map(\.id)).count == messages.count else { error = "Duplicate messages cannot be saved."; return false }
        guard preferences.monthlyBudget.isFinite, (0...1_000_000_000_000).contains(preferences.monthlyBudget), preferences.bulletinTitle.count <= 200, preferences.bulletinBody.count <= 10000 else {
            error = "Check your budget and announcement length."; return false
        }
        do {
            var updated = snapshots
            let profileChanged = try Self.profileData(profile) != snapshots[scope].map { try Self.profileData($0.profile) }
            let pending = !applyingCloudProfile && (profileChanged || snapshots[scope]?.profilePendingUpload == true)
            let snapshot = Snapshot(records: records, profile: profile, messages: messages, preferences: preferences, categoryCorrections: categoryCorrections, profilePendingUpload: pending, cloudBaseline: cloudBaselineOverride ?? snapshots[scope]?.cloudBaseline)
            updated[scope] = snapshot
            try persist(snapshot, scope: scope)
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
