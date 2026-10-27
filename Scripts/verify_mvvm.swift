import Foundation
import Combine

@MainActor
private final class MVVMSessionStorage: AuthSessionStorage {
    func load() throws -> SavedAuthSession? { nil }
    func save(_ value: SavedAuthSession) throws {}
    func clear() throws {}
}

private final class MVVMNetwork: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.notConnectedToInternet) }
            let (status, object) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct VerifyMVVM {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "HomeMate.MVVMTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeMateMVVM-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HouseholdStore(storageURL: directory.appendingPathComponent("test.sqlite"), notificationsEnabled: false)
        let suite = "HomeMateMVVM-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MVVMNetwork.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let account = CloudAccount(apiKey: "test", projectID: "demo-homemate", session: session, storage: MVVMSessionStorage(), sessionPreferences: preferences)

        let setup = WelcomeViewModel(store: store, account: account)
        setup.draft.name = "Guest"
        try require(store.profile.name.isEmpty, "Setup typing must not mutate stored profile")
        setup.save()
        try require(store.profile.name == "Guest" && store.profile.onboarded, "Setup must save its draft")
        let offlineMore = MoreViewModel(store: store, account: account)
        await offlineMore.refreshFamily()
        try require(offlineMore.displayName == "Guest" && offlineMore.memberNames == ["Guest"] && offlineMore.family == nil, "More must use the local profile without inventing accepted family members")
        let settings = SettingsViewModel(store: store, account: account)
        settings.prepareDraft(); settings.draftProfile.currency = "INVALID"
        try require(!settings.saveDraft() && store.profile.currency == "LKR", "Invalid settings must roll back")
        store.error = nil

        let records = RecordsViewModel(store: store, account: account, kind: .task)
        var redraws = 0
        let observer = records.objectWillChange.sink { redraws += 1 }
        records.search = "wash"
        try require(redraws > 0, "Subclass @Published state must notify its observed ViewModel")
        let beforeStoreChange = redraws
        let task = HouseholdRecord(kind: .task, title: "Wash dishes")
        let editor = RecordEditorViewModel(store: store, account: account, record: task, sharedAssignees: nil, onSave: nil)
        let newTaskEditor = RecordEditorViewModel(store: store, account: account, record: HouseholdRecord(kind: .task, title: ""), sharedAssignees: nil, onSave: nil)
        try require(newTaskEditor.record.date.timeIntervalSinceNow > 3_500, "A new task must not be overdue before the form is completed")
        let saved = await editor.save()
        try require(saved && store.records.count == 1, "Personal editor must save through repository")
        try require(redraws > beforeStoreChange, "Repository changes must notify feature ViewModels")
        try require(records.filtered.map(\.id) == [task.id], "Search must use current repository values")
        records.search = "missing"; try require(records.filtered.isEmpty, "Search must exclude non-matches")
        records.search = ""; records.toggle(task); records.showCompleted = false
        try require(records.filtered.isEmpty && records.open == 0, "Completion and visibility must stay consistent")
        let maintenanceTask = HouseholdRecord(kind: .maintenance, title: "Service water pump", date: Date())
        try require(store.upsert(maintenanceTask), "Maintenance fixture must save")
        try require(records.filtered.map(\.id) == [maintenanceTask.id] && records.open == 1, "All Tasks must include open maintenance work")
        let taskDashboard = DashboardViewModel(store: store, account: account)
        try require(taskDashboard.tasks.contains(where: { $0.id == maintenanceTask.id }), "Today's Tasks must include maintenance work")
        let navigation = NavigationViewModel(store: store, account: account)
        try require(navigation.nextTask?.id == maintenanceTask.id, "Tasks tab must open the next pending task's details")
        try require(navigation.overdueTasks.map(\.id) == [maintenanceTask.id], "Overdue filter must contain only overdue open tasks")
        try require(navigation.completedTasks.contains(where: { $0.id == task.id }), "Completed filter must contain completed tasks")
        try require(navigation.otherTasks.contains(where: { $0.id == maintenanceTask.id }), "Other filter must follow the saved category")
        let overdueDetail = RecordDetailViewModel(store: store, account: account, record: maintenanceTask)
        try require(overdueDetail.isOverdue && overdueDetail.statusTitle == "Overdue", "An overdue activity must have one relevant status")
        store.delete(maintenanceTask)
        observer.cancel()
        let dueBill = HouseholdRecord(kind: .bill, title: "Internet bill", amount: 750,
                                      date: Date().addingTimeInterval(86_400))
        try require(store.upsert(dueBill), "Personal bill fixture must save")
        let billDetail = RecordDetailViewModel(store: store, account: account, record: dueBill)
        let expenses = RecordsViewModel(store: store, account: account, kind: .expense)
        try require(expenses.filtered.isEmpty, "An unpaid bill must stay out of Expenses")
        billDetail.toggleCompletion()
        try require(expenses.filtered.map(\.id) == [dueBill.id] &&
                    expenses.spendingThisMonth == 750 &&
                    store.records.first(where: { $0.id == dueBill.id })?.paidAt != nil,
                    "Mark paid from bill details must immediately appear once in Expenses and monthly spending")
        billDetail.toggleCompletion()
        try require(expenses.filtered.isEmpty && expenses.spendingThisMonth == 0,
                    "Reopening a paid bill must remove it from Expenses")
        store.delete(dueBill)

        let invalid = RecordEditorViewModel(store: store, account: account, record: HouseholdRecord(kind: .bill, title: "", amount: -1), sharedAssignees: nil, onSave: nil)
        let invalidSaved = await invalid.save()
        try require(!invalidSaved && store.records.count == 1, "Invalid editor input must never persist")
        var sharedWrites = 0
        let shared = RecordEditorViewModel(store: store, account: account, record: HouseholdRecord(kind: .bill, title: "Shared bill", amount: 100), sharedAssignees: ["member@example.test"], onSave: { _ in sharedWrites += 1 })
        let sharedSaved = await shared.save()
        try require(sharedSaved && sharedWrites == 1 && store.records.count == 1, "Shared editor must call its callback without a local insert")
        let failing = RecordEditorViewModel(store: store, account: account, record: task, sharedAssignees: [], onSave: { _ in throw URLError(.cannotConnectToHost) })
        let failureSaved = await failing.save()
        try require(!failureSaved && failing.saveError != nil && !failing.saving, "Shared failure must stay visible and clear busy state")

        let dashboard = DashboardViewModel(store: store, account: account)
        dashboard.prepareBudget(); dashboard.budgetDraft = 5000
        try require(store.preferences.monthlyBudget != 5000, "Budget draft must not persist before Save")
        dashboard.saveBudget(); try require(store.preferences.monthlyBudget == 5000, "Budget Save must persist")
        dashboard.budgetDraft = -.infinity; dashboard.saveBudget()
        try require(store.preferences.monthlyBudget == 5000, "Invalid budget must preserve saved data")
        store.error = nil
        let reopened = HouseholdStore(storageURL: directory.appendingPathComponent("test.sqlite"), notificationsEnabled: false)
        try require(reopened.records.count == 1 && reopened.preferences.monthlyBudget == 5000, "ViewModel saves must survive repository reopening")
        let calendar = CalendarViewModel(store: store, account: account)
        calendar.selectedDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        calendar.visibleMonth = calendar.selectedDate; calendar.moveMonth(1)
        try require(Calendar.current.component(.day, from: calendar.selectedDate) == 28, "Calendar navigation must preserve valid dates")

        let eventDate = Date(timeIntervalSince1970: 1_800_000_000)
        var eventRecord = HouseholdRecord(kind: .event, title: "  Family dinner  ", date: eventDate, notes: "Bring dessert", location: " Home ")
        let eventEditor = RecordEditorViewModel(store: store, account: account, record: eventRecord, sharedAssignees: nil, onSave: nil)
        eventEditor.prepareCalendarExport()
        try require(eventEditor.calendarDraft?.title == "Family dinner" && eventEditor.calendarDraft?.location == "Home", "Calendar export must map clean event details")
        try require(eventEditor.calendarDraft?.endDate == eventDate.addingTimeInterval(3600), "Events without an end time must default to one hour")
        try require(eventEditor.calendarDraft?.notes == "Bring dessert" && store.records.count == 1, "Preparing an export must preserve notes without saving an app record")
        eventEditor.completeCalendarExport(.cancelled)
        try require(eventEditor.calendarDraft == nil && eventEditor.calendarMessage == nil, "Cancelled system editor must not report success")
        eventRecord.endDate = eventDate.addingTimeInterval(7200); eventEditor.record = eventRecord
        eventEditor.prepareCalendarExport()
        try require(eventEditor.calendarDraft?.endDate == eventRecord.endDate, "Calendar export must preserve an explicit end time")
        eventEditor.completeCalendarExport(.saved)
        try require(eventEditor.calendarDraft == nil && eventEditor.calendarMessage != nil, "System save callback must dismiss the editor and show confirmation")
        eventRecord.endDate = eventDate; eventEditor.record = eventRecord
        eventEditor.prepareCalendarExport()
        try require(eventEditor.calendarDraft == nil && eventEditor.calendarFailed, "Zero-length events must be rejected before presenting the calendar")
        editor.prepareCalendarExport()
        try require(editor.calendarDraft == nil && editor.calendarFailed, "Tasks must not export as calendar events")

        let login = LoginViewModel(store: store, account: account)
        account.email = "not-an-email"; account.password = "x"; await login.submit()
        try require(login.showingError && !account.signedIn, "Invalid login must stop before networking")
        login.switchMode(); account.email = "alice@example.test"; account.password = "password123"; login.confirmation = "different"
        await login.submit(); try require(login.localError == "The passwords do not match.", "Registration confirmation must be checked in ViewModel")
        login.confirmation = account.password
        MVVMNetwork.handler = { request in
            guard request.url!.path.hasSuffix("accounts:signUp") else { throw URLError(.badURL) }
            return (200, ["idToken":"test-token", "localId":"alice", "refreshToken":"test-refresh", "email":"alice@example.test", "expiresIn":"3600"])
        }
        await login.submit()
        try require(account.signedIn && account.userID == "alice", "Login ViewModel must delegate registration to the injected auth service")
        store.activate(userID: account.userID)
        let staleSaved = await editor.save()
        dashboard.budgetDraft = 8888; dashboard.saveBudget()
        try require(!staleSaved && store.records.isEmpty && store.preferences.monthlyBudget != 8888, "Old guest ViewModels must not write into a signed-in account")
        eventEditor.record.endDate = eventDate.addingTimeInterval(3600)
        eventEditor.prepareCalendarExport()
        try require(eventEditor.calendarDraft == nil, "A stale account's editor must not prepare a calendar export")

        let cloud = CloudRecordsViewModel(store: store, account: account)
        MVVMNetwork.handler = { _ in (200, ["documents":[]]) }
        await cloud.load()
        try require(cloud.records.isEmpty && !cloud.busy && !cloud.message.isEmpty, "Empty cloud state must finish loading and explain itself")
        MVVMNetwork.handler = { _ in (403, ["error":["message":"PERMISSION_DENIED"]]) }
        await cloud.load()
        try require(cloud.records.isEmpty && !cloud.busy && !cloud.message.isEmpty, "Cloud failure must not leave stale data or busy state")
        let family = SharedFamily(id: "family", name: "Test family", ownerID: "alice", currency: "LKR")
        let sharedRecords = SharedFamilyViewModel(store: store, account: account, family: family)
        await sharedRecords.refresh()
        try require(sharedRecords.records.isEmpty && sharedRecords.error != nil && !sharedRecords.loading, "Shared access failure must clear data and show an error")
        let sharedReceipt = HouseholdRecord(kind: .expense, title: "Groceries", amount: 1000)
        let sharedUnpaidBill = HouseholdRecord(kind: .bill, title: "Water", amount: 500)
        var sharedPaidBill = HouseholdRecord(kind: .bill, title: "Electricity", amount: 800, completed: true)
        sharedPaidBill.paidAt = Date()
        sharedRecords.records = [sharedReceipt, sharedUnpaidBill, sharedPaidBill]
        sharedRecords.kind = .expense
        try require(Set(sharedRecords.filtered.map(\.id)) == Set([sharedReceipt.id, sharedPaidBill.id]),
                    "Family Expenses must include paid bills exactly once and exclude unpaid bills")
        let chat = SharedFamilyChatViewModel(store: store, account: account, family: family)
        chat.text = "   "; try require(!chat.canSend, "Shared chat must reject blank messages")
        chat.text = String(repeating: "x", count: 4001); try require(!chat.canSend, "Shared chat must enforce message length")
        chat.text = "Hello"; await chat.send()
        try require(chat.text == "Hello" && chat.error != nil && !chat.sending, "A failed send must preserve the draft")

        let more = MoreViewModel(store: store, account: account)
        MVVMNetwork.handler = { request in
            let path = request.url!.path
            if request.url!.host == "securetoken.googleapis.com" { return (200, ["id_token":"verified-token", "refresh_token":"test-refresh", "user_id":"alice", "expires_in":"3600"]) }
            if path.hasSuffix("accounts:lookup") { return (200, ["users":[["emailVerified":true]]]) }
            if path.hasSuffix("/users/alice/families") {
                return (200, ["documents":[["name":"projects/demo-homemate/databases/(default)/documents/users/alice/families/family", "fields":["familyID":["stringValue":"family"]]]]])
            }
            if path.hasSuffix("/families/family") {
                return (200, ["fields":["name":["stringValue":"Our family"], "ownerID":["stringValue":"alice"], "currency":["stringValue":"LKR"]]])
            }
            if path.hasSuffix("/families/family/members") {
                return (200, ["documents":[["fields":["uid":["stringValue":"alice"], "email":["stringValue":"alice@example.test"], "displayName":["stringValue":"Alice"], "role":["stringValue":"owner"]]]]])
            }
            throw URLError(.badURL)
        }
        await more.refreshFamily()
        try require(more.householdTitle == "Our family" && more.memberNames == ["Alice"] && more.memberSummary == "1 member", "More must load only accepted family members from the authenticated service")
        try require(more.ownerSummary == "Alice · Owner" && !more.familyLoading, "More must show the real family owner and finish loading")
        MVVMNetwork.handler = { _ in (403, ["error":["message":"PERMISSION_DENIED"]]) }
        await more.refreshFamily()
        try require(more.family == nil && more.members.isEmpty && more.familyMessage != nil && !more.familyLoading, "More must clear old family details if membership or access cannot be confirmed")
        print("MVVM checks passed: published updates, draft isolation, validation, disk persistence, save routing, calendar export, More family overview, conflicts/errors, login, account lifetime and shared access failures.")
    }
}
