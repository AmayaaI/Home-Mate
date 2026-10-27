import Foundation
import CoreData

@main struct VerifyStore {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "HomeMateStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeMateTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("accounts.sqlite")
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        try require(store.error == nil, "Database must open")
        let guest = HouseholdRecord(kind: .task, title: "Guest task")
        try require(store.upsert(guest), "Guest save failed")
        store.activate(userID: "alice")
        try require(store.records.isEmpty && store.profile.name.isEmpty && store.messages.isEmpty, "New account must not inherit guest data")
        store.profile.name = "Alice"; store.profile.household = "Alice Home"; store.profile.members = "Alice"; store.profile.onboarded = true
        store.messages = [ChatMessage(author: "Alice", text: "Private message")]
        store.preferences.monthlyBudget = 12000; store.preferences.bulletinTitle = "Alice only"
        let alice = HouseholdRecord(kind: .bill, title: "  Alice bill  ", amount: 150)
        try require(store.upsert(alice), "Alice save failed")
        store.activate(userID: "bob")
        try require(store.records.isEmpty && store.profile.name.isEmpty && store.messages.isEmpty && store.preferences.monthlyBudget == 0 && store.preferences.bulletinTitle.isEmpty, "Bob must not see Alice's records, profile, chat, or budget")
        try require(store.upsert(HouseholdRecord(kind: .task, title: "Bob task")), "Bob save failed")
        store.activate(userID: nil)
        try require(store.records.map(\.id) == [guest.id], "Sign out must show only guest storage")
        store.activate(userID: "alice")
        try require(store.records.map(\.id) == [alice.id] && store.records[0].title == "Alice bill", "Alice records not restored or not trimmed")
        try require(store.profile.name == "Alice" && store.messages.count == 1 && store.preferences.monthlyBudget == 12000, "Alice household state must survive account switching")
        let reloaded = HouseholdStore(storageURL: url, notificationsEnabled: false)
        reloaded.activate(userID: "alice")
        try require(reloaded.records.map(\.id) == [alice.id] && reloaded.preferences.bulletinTitle == "Alice only", "Account data must survive database reopen")
        let syncStore = HouseholdStore(storageURL: directory.appendingPathComponent("sync.sqlite"), notificationsEnabled: false)
        syncStore.activate(userID: "alice")
        syncStore.profile = reloaded.profile
        try require(syncStore.save(), "Sync fixture must save")
        try require(syncStore.profilePendingUpload, "Offline profile edits must survive restart")
        let uploaded = try HouseholdStore.profileData(syncStore.profile)
        syncStore.profile.name = "Alice updated"
        try require(syncStore.save(), "Profile edit failed")
        syncStore.acknowledgeProfile(uploaded, expectedScope: syncStore.scope)
        try require(syncStore.profilePendingUpload, "A stale upload must not clear newer edits")
        syncStore.acknowledgeProfile(try HouseholdStore.profileData(syncStore.profile), expectedScope: syncStore.scope)
        try require(!syncStore.profilePendingUpload, "Successful upload must clear pending state")
        try require(syncStore.upsert(alice), "Record save failed")
        try require(!syncStore.profilePendingUpload, "Record edits must not dirty the profile")
        var remote = syncStore.profile
        remote.name = "From another device"
        try require(syncStore.restoreProfile(remote, expectedScope: syncStore.scope), "Cloud profile restore failed")
        try require(syncStore.profile.name == remote.name && !syncStore.profilePendingUpload, "Restore must not enqueue another upload")
        syncStore.activate(userID: "bob")
        try require(!syncStore.restoreProfile(remote, expectedScope: "user:alice"), "Late cloud responses must not cross accounts")
        syncStore.activate(userID: "alice")
        let captured = syncStore.accountSnapshot
        var fromCloud = captured
        fromCloud.records = [HouseholdRecord(kind: .event, title: "Cloud event")]
        syncStore.preferences.monthlyBudget = 23000
        try require(syncStore.save(), "Edit during upload must save")
        try syncStore.acceptAccountSnapshot(fromCloud, sent: captured, expectedScope: "user:alice")
        try require(syncStore.preferences.monthlyBudget == 23000 && syncStore.records.first?.title == "Cloud event", "Restore must preserve edits made during network requests")
        let syncedReopen = HouseholdStore(storageURL: directory.appendingPathComponent("sync.sqlite"), notificationsEnabled: false)
        syncedReopen.activate(userID: "alice")
        try require(syncedReopen.accountBaseline.records.first?.title == "Cloud event" && syncedReopen.preferences.monthlyBudget == 23000, "Baseline and pending edits must survive restart")
        print("PASS: account sync baseline persistence and edits during upload")
        var invalid = alice; invalid.amount = -1
        try require(!store.upsert(invalid) && store.records[0].amount == 150, "Invalid writes must not mutate records")
        invalid.amount = .infinity
        try require(!store.upsert(invalid), "Infinite amounts must be rejected")
        invalid = alice; invalid.title = " \n "
        try require(!store.upsert(invalid), "Whitespace titles must be rejected")
        invalid = alice; invalid.endDate = invalid.date.addingTimeInterval(-60)
        try require(!store.upsert(invalid), "Reversed dates must be rejected")
        try require(!store.replaceRecords([alice, alice], expectedScope: store.scope) && store.records.count == 1, "Duplicate cloud restore must roll back")
        try require(!store.replaceRecords([], expectedScope: "user:bob") && store.records.count == 1, "Stale restore must not replace another user's data")
        var invalidPreferences = store.preferences; invalidPreferences.monthlyBudget = -5
        try require(!store.updatePreferences(invalidPreferences) && store.preferences.monthlyBudget == 12000, "Invalid preference updates must roll back")
        try require(!store.replaceMessages([ChatMessage(author: "Alice", text: String(repeating: "x", count: 10001))]) && store.messages.count == 1, "Invalid chat writes must roll back")
        store.profile.name = ""; try require(!store.save(), "Onboarded profile needs a name")
        store.profile.name = "Alice"
        try require(InputValidation.email("a+b@example.com") && !InputValidation.email("a@") && !InputValidation.email("a b@example.com"), "Email validation failed")
        try require(InputValidation.phone("+94 77 123 4567") && !InputValidation.phone("hello") && !InputValidation.phone("123"), "Phone validation failed")
        try require(InputValidation.mobile("0771234567", countryCode: "+94") && InputValidation.mobile("771234567", countryCode: "+94"), "Sri Lankan mobile formats must work")
        try require(!InputValidation.mobile("1234567", countryCode: "+94") && !InputValidation.mobile("07712345678", countryCode: "+94") && !InputValidation.mobile("0771234567", countryCode: "94"), "Invalid mobile lengths and country codes must fail")
        try require(!InputValidation.phone("077+1234567") && !InputValidation.phone("++94771234567"), "Phone plus signs must only appear once at the beginning")
        var profile = HouseholdProfile(); profile.members = "Sam, sam, Nimal"
        try require(profile.memberNames == ["Sam", "Nimal"], "Member names must be deduplicated without changing their case")
        print("PASS: mobile country-code validation and member name deduplication")
        print("PASS: guest/Alice/Bob separation; per-account records, profile, chat, budget; disk reopen; invalid writes and restores; email/phone validation")
        store.activate(userID: "completion-check")
        let firstTask = HouseholdRecord(kind: .task, title: "First new task")
        try require(store.upsert(firstTask) && store.records.first?.completed == false, "A newly saved task must start pending")
        var editedTask = firstTask; editedTask.title = "Updated task title"; editedTask.notes = "Keep these newer details"
        try require(store.upsert(editedTask), "Task edit must save")
        store.toggle(firstTask)
        try require(store.records.first?.completed == true && store.records.first?.title == editedTask.title && store.records.first?.notes == editedTask.notes, "Completion from an older row must preserve newer saved details")
        store.toggle(firstTask)
        try require(store.records.first?.completed == true, "Repeating the same Complete action must not reopen the task")
        let secondTask = HouseholdRecord(kind: .task, title: "Second new task")
        try require(store.upsert(secondTask) && store.records.first(where: { $0.id == secondTask.id })?.completed == false, "A new task must not inherit a previous task's completion")
        let completionReload = HouseholdStore(storageURL: url, notificationsEnabled: false)
        completionReload.activate(userID: "completion-check")
        try require(completionReload.records.first(where: { $0.id == firstTask.id })?.completed == true && completionReload.records.first(where: { $0.id == secondTask.id })?.completed == false, "Pending and completed states must survive reopening")
        let completedTask = store.records.first(where: { $0.id == firstTask.id })!
        store.toggle(completedTask)
        try require(store.records.first(where: { $0.id == firstTask.id })?.completed == false, "Reopen must return a completed task to pending")
        store.toggle(completedTask)
        try require(store.records.first(where: { $0.id == firstTask.id })?.completed == false, "Repeating an older Reopen action must keep the task pending")
        let reopenedTasks = HouseholdStore(storageURL: url, notificationsEnabled: false)
        reopenedTasks.activate(userID: "completion-check")
        try require(reopenedTasks.records.first(where: { $0.id == firstTask.id })?.completed == false, "Reopened state must persist")
        store.delete(secondTask); store.toggle(secondTask)
        try require(!store.records.contains(where: { $0.id == secondTask.id }), "An old completion action must not recreate a deleted task")
        print("PASS: new tasks stay pending; completion preserves current data; repeated actions are safe; statuses survive reopening; deleted tasks stay deleted")
        store.activate(userID: "spending-check")
        let receipt = HouseholdRecord(kind: .expense, title: "Groceries receipt", amount: 1200, category: "Groceries")
        let futureBill = HouseholdRecord(kind: .bill, title: "Electricity due", amount: 800, date: Date().addingTimeInterval(86_400), category: "Utilities")
        try require(store.upsert(receipt) && store.upsert(futureBill), "Receipt and upcoming bill must save separately")
        try require(store.monthlyExpenses.map(\.id) == [receipt.id], "An unpaid bill must not count as spending")
        store.toggle(futureBill)
        let paidBill = store.records.first { $0.id == futureBill.id }!
        try require(paidBill.completed && paidBill.paidAt != nil && store.monthlyExpenses.count == 2, "Paying a bill must add it to the paid month's spending")
        let spendingReload = HouseholdStore(storageURL: url, notificationsEnabled: false)
        spendingReload.activate(userID: "spending-check")
        try require(spendingReload.records.first { $0.id == futureBill.id }?.paidAt != nil && spendingReload.monthlyExpenses.count == 2, "Paid bill and spending must persist")
        store.toggle(paidBill)
        try require(store.records.first { $0.id == futureBill.id }?.paidAt == nil && store.monthlyExpenses.count == 1, "Reopening a bill must remove it from spending")
        print("PASS: scanned expense and unpaid bill stay separate; paid bills count once in spending and survive reload")
        // Exercise the previous unscoped database representation: it must only migrate to guest.
        struct Legacy: Codable { var records: [HouseholdRecord]; var profile = HouseholdProfile(); var messages: [ChatMessage] = [] }
        let legacyURL = directory.appendingPathComponent("legacy.sqlite")
        let legacy = HouseholdStore(storageURL: legacyURL, notificationsEnabled: false)
        // Use the same programmatic model to populate a real legacy snapshot.
        let model = NSManagedObjectModel(); let entity = NSEntityDescription(); entity.name = "LocalSnapshot"; entity.managedObjectClassName = "NSManagedObject"
        let payload = NSAttributeDescription(); payload.name = "payload"; payload.attributeType = .binaryDataAttributeType; entity.properties = [payload]; model.entities = [entity]
        let container = NSPersistentContainer(name: "HomeMate", managedObjectModel: model)
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: legacyURL)]
        container.loadPersistentStores { _, error in precondition(error == nil) }
        let object = NSEntityDescription.insertNewObject(forEntityName: "LocalSnapshot", into: container.viewContext)
        object.setValue(try JSONEncoder().encode(Legacy(records: [guest])), forKey: "payload"); try container.viewContext.save()
        _ = legacy
        let migrated = HouseholdStore(storageURL: legacyURL, notificationsEnabled: false)
        try require(migrated.records.first?.id == guest.id, "Legacy data must be preserved in guest")
        migrated.activate(userID: "alice")
        try require(migrated.records.isEmpty, "Legacy shared data must never be assigned to a new account")
        try require(migrated.save(), "Migrated envelope must save")
        migrated.activate(userID: nil)
        try require(migrated.records.first?.id == guest.id, "Guest legacy data must remain after migration save")
        print("PASS: existing shared-data migration preserves guest data without leaking it to online accounts")
    }
}
