import Foundation
import Testing
@testable import HomeMate

@MainActor
private final class VisibilityMemorySession: AuthSessionStorage {
    func load() throws -> SavedAuthSession? { nil }
    func save(_ session: SavedAuthSession) throws {}
    func clear() throws {}
}

/// Exercises the real REST codec and destination routing without contacting production.
private final class VisibilityHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let value: [String: Any]
        if path.contains("signInWithPassword") {
            value = ["idToken": "fixture", "localId": "member", "refreshToken": "fixture", "expiresIn": "3600"]
        } else if path.hasSuffix("users/member/families") {
            value = ["documents": [["fields": ["familyID": ["stringValue": "chosen"]]]]]
        } else if path.hasSuffix("families/chosen") {
            value = ["fields": ["name": ["stringValue": "Chosen family"], "ownerID": ["stringValue": "member"], "currency": ["stringValue": "LKR"]]]
        } else if path.hasSuffix("families/chosen/members") {
            value = ["documents": [["fields": ["uid": ["stringValue": "member"], "email": ["stringValue": "member@example.test"], "displayName": ["stringValue": "Member"], "role": ["stringValue": "owner"]]]]]
        } else if path.hasSuffix("families/chosen:runQuery") {
            value = ["documents": []]
        } else if path.contains("families/chosen/records/") && request.httpMethod == "PATCH" {
            value = [:]
        } else if path.hasSuffix("families/chosen/records") || path.hasSuffix("families/chosen/announcements") || path.hasSuffix("families/chosen/invitations") {
            value = ["documents": []]
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

/// Pure logic tests and isolated temporary stores. No production Firebase or Keychain writes.
struct ValidationTests {
    @Test func optionalCoordinatesPreserveLegacyDecoding() throws {
        let record = HouseholdRecord(kind: .task, title: "Old record")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(HouseholdRecord.self, from: data)
        #expect(decoded.latitude == nil && decoded.longitude == nil)
        #expect(decoded.validationError == nil)
    }
    @Test func coordinatesRejectIncompleteAndInvalidPairs() {
        var record = HouseholdRecord(kind: .task, title: "Errand")
        record.latitude = 6.9
        #expect(record.validationError != nil)
        record.longitude = 79.8
        #expect(record.validationError == nil)
        record.latitude = 91
        #expect(record.validationError != nil)
        record.latitude = .nan
        #expect(record.validationError != nil)
    }
    @Test func coordinatesRoundTripThroughCloudCodec() throws {
        var record = HouseholdRecord(kind: .task, title: "Groceries")
        record.latitude = 6.9271; record.longitude = 79.8612
        let decoded = try FirestoreRecordCodec.decode(FirestoreRecordCodec.encode(record))
        #expect(decoded.latitude == record.latitude && decoded.longitude == record.longitude)
    }
    @Test func reminderPreferenceRoundTripsAndOldRecordsKeepHouseholdDefault() throws {
        var record = HouseholdRecord(kind: .task, title: "Medication", date: Date().addingTimeInterval(7_200))
        record.reminderEnabled = false
        record.reminderDate = Date().addingTimeInterval(3_600)
        #expect(try FirestoreRecordCodec.decode(FirestoreRecordCodec.encode(record)).reminderEnabled == false)
        let roundTrippedReminder = try #require(FirestoreRecordCodec.decode(FirestoreRecordCodec.encode(record)).reminderDate)
        // The REST codec serialises fractional seconds at millisecond precision.
        #expect(abs(roundTrippedReminder.timeIntervalSince(try #require(record.reminderDate))) < 0.001)
        #expect(try FirestoreRecordCodec.decode(FirestoreRecordCodec.encode(HouseholdRecord(kind: .task, title: "Legacy"))).reminderEnabled == nil)
    }
    @Test func customReminderMustBeBeforeActivity() {
        var record = HouseholdRecord(kind: .task, title: "Medication", date: Date().addingTimeInterval(7_200))
        record.reminderDate = Date().addingTimeInterval(7_300)
        #expect(record.validationError != nil)
        record.reminderDate = Date().addingTimeInterval(3_600)
        #expect(record.validationError == nil)
    }
    @Test func regionPolicyRespectsAssignmentAndCompletion() {
        var record = HouseholdRecord(kind: .task, title: "Groceries", assignee: "nimal@example.com")
        record.latitude = 6.9271; record.longitude = 79.8612
        #expect(ErrandRegionPolicy.eligible([record], shared: true, email: "sarah@example.com", localName: "Sarah").isEmpty)
        #expect(ErrandRegionPolicy.eligible([record], shared: true, email: "nimal@example.com", localName: "Nimal").count == 1)
        record.completed = true
        #expect(ErrandRegionPolicy.eligible([record], shared: true, email: "nimal@example.com", localName: "Nimal").isEmpty)
        record.completed = false; record.assignee = "Everyone"
        #expect(ErrandRegionPolicy.eligible([record], shared: true, email: "sarah@example.com", localName: "Sarah").count == 1)
        record.kind = .expense
        #expect(ErrandRegionPolicy.eligible([record], shared: true, email: "sarah@example.com", localName: "Sarah").isEmpty)
    }
    @Test func radiusIsBounded() {
        #expect(ErrandRegionPolicy.validRadius(100)); #expect(ErrandRegionPolicy.validRadius(1000))
        #expect(!ErrandRegionPolicy.validRadius(0)); #expect(!ErrandRegionPolicy.validRadius(.infinity))
    }
    @Test func emailValidation() {
        #expect(InputValidation.email("person@example.com"))
        #expect(!InputValidation.email("person"))
        #expect(!InputValidation.email("person@"))
        #expect(!InputValidation.email("person name@example.com"))
    }
    @Test func taskTitleValidation() {
        #expect(HouseholdRecord(kind: .task, title: " ").validationError != nil)
        #expect(HouseholdRecord(kind: .task, title: String(repeating: "a", count: 201)).validationError != nil)
        #expect(HouseholdRecord(kind: .task, title: "Clean kitchen").validationError == nil)
    }
    @Test func billAmounts() {
        for amount in [-1.0, Double.infinity, Double.nan, 1_000_000_000_001] {
            #expect(HouseholdRecord(kind: .bill, title: "Bill", amount: amount).validationError != nil)
        }
        #expect(HouseholdRecord(kind: .bill, title: "Bill", amount: 0).validationError == nil)
    }
    @Test func eventEndMustFollowStart() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(HouseholdRecord(kind: .event, title: "Dinner", date: start, endDate: start.addingTimeInterval(-1)).validationError != nil)
    }
    @Test func calendarExportRejectsPastActivities() {
        let task = HouseholdRecord(kind: .task, title: "Past task", date: Date().addingTimeInterval(-60))
        #expect(throws: (any Error).self) { try CalendarExportService.draft(from: task) }
    }
    @Test func invitationRecipientAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let invite = FamilyInvitation(id: "invite", familyID: "family", familyName: "Home", email: "member@example.com", expiresAt: now.addingTimeInterval(1))
        #expect(invite.canAccept(email: "MEMBER@example.com", verified: true, now: now))
        #expect(!invite.canAccept(email: "other@example.com", verified: true, now: now))
        #expect(!invite.canAccept(email: invite.email, verified: false, now: now))
        #expect(!invite.canAccept(email: invite.email, verified: true, now: invite.expiresAt))
    }
    @Test func codecRetainsPaymentAndRevision() throws {
        let paid = Date(timeIntervalSince1970: 1_800_000_000)
        let bill = HouseholdRecord(kind: .bill, title: "Water", amount: 500, completed: true, paidAt: paid)
        var document = try FirestoreRecordCodec.encode(bill)
        document["updateTime"] = "revision"
        let decoded = try FirestoreRecordCodec.decode(document)
        #expect(decoded.paidAt == paid)
        #expect(decoded.completed)
        #expect(decoded.cloudRevision == "revision")
    }
    @Test func billReferenceRoundTripsAndLegacyRecordsStillDecode() throws {
        let bill = HouseholdRecord(kind: .bill, title: "Electricity", amount: 8500, referenceNumber: "CEB-12345")
        #expect(try FirestoreRecordCodec.decode(FirestoreRecordCodec.encode(bill)).referenceNumber == "CEB-12345")
        #expect(try FirestoreRecordCodec.decode(FirestoreRecordCodec.encode(HouseholdRecord(kind: .bill, title: "Legacy"))).referenceNumber == nil)
    }
    @Test func billFiltersSeparateOverdueUpcomingAndPaid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overdue = HouseholdRecord(kind: .bill, title: "Overdue", date: now.addingTimeInterval(-60))
        let upcoming = HouseholdRecord(kind: .bill, title: "Upcoming", date: now.addingTimeInterval(60))
        let paid = HouseholdRecord(kind: .bill, title: "Paid", date: now.addingTimeInterval(-60), completed: true)
        #expect(BillFilter.overdue.includes(overdue, now: now))
        #expect(!BillFilter.overdue.includes(upcoming, now: now))
        #expect(BillFilter.upcoming.includes(upcoming, now: now))
        #expect(BillFilter.paid.includes(paid, now: now))
        #expect(BillFilter.toPay.includes(overdue, now: now))
        #expect(!BillFilter.toPay.includes(paid, now: now))
    }
    @Test func codecRejectsMalformedPayment() throws {
        var document = try FirestoreRecordCodec.encode(HouseholdRecord(kind: .bill, title: "Water"))
        var fields = try #require(document["fields"] as? [String: Any])
        fields["paidAt"] = ["stringValue": "not a timestamp"]
        document["fields"] = fields
        #expect(throws: (any Error).self) { try FirestoreRecordCodec.decode(document) }
    }
    @Test func legacyPaidBillWithoutTimestamp() throws {
        let original = HouseholdRecord(kind: .bill, title: "Legacy", completed: true)
        let decoded = try FirestoreRecordCodec.decode(FirestoreRecordCodec.encode(original))
        #expect(decoded.paidAt == nil)
        #expect(ExpenseIntelligence.spendingDate(for: decoded) == decoded.date)
    }
    @Test func backwardCompatibleLocalRecord() throws {
        let record = HouseholdRecord(kind: .task, title: "Legacy")
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(HouseholdRecord.self, from: data).title == "Legacy")
    }
    @Test func priorityUsesImportanceAndUrgency() {
        let later = Date().addingTimeInterval(86400 * 10)
        let normal = HouseholdRecord(kind: .task, title: "Normal", date: later)
        let important = HouseholdRecord(kind: .task, title: "Important", date: later, important: true)
        let overdue = HouseholdRecord(kind: .task, title: "Overdue", date: Date().addingTimeInterval(-3600))
        #expect(important.priority > normal.priority)
        #expect(overdue.priority > normal.priority)
    }
    @Test func taskFiltersKeepHouseholdsAndAssignmentsDistinct() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mine = HouseholdRecord(kind: .task, title: "Mine", date: now.addingTimeInterval(3600), assignee: "nimal@example.com")
        let everyone = HouseholdRecord(kind: .task, title: "Everyone", date: now.addingTimeInterval(3600), assignee: "Everyone")
        let other = HouseholdRecord(kind: .task, title: "Other", date: now.addingTimeInterval(3600), assignee: "sarah@example.com")
        #expect(TaskFilter.mine.includes(mine, shared: true, accountEmail: "nimal@example.com", localName: "Nimal", now: now))
        #expect(TaskFilter.mine.includes(everyone, shared: true, accountEmail: "nimal@example.com", localName: "Nimal", now: now))
        #expect(!TaskFilter.mine.includes(other, shared: true, accountEmail: "nimal@example.com", localName: "Nimal", now: now))
    }
    @Test func sharedAssignmentLabelsUseNamesAndOneSelfLabel() {
        let members = [
            FamilyMember(id: "amaya", email: "amaya@example.com", displayName: "Amaya1", role: "owner"),
            FamilyMember(id: "sandaru", email: "sandaru@example.com", displayName: "Sandaru", role: "member")
        ]
        #expect(AssignmentDisplay.label(for: "amaya@example.com", accountEmail: "amaya@example.com", localName: "Amaya1", members: members, shared: true) == "Me")
        #expect(AssignmentDisplay.label(for: "sandaru@example.com", accountEmail: "amaya@example.com", localName: "Amaya1", members: members, shared: true) == "Sandaru")
        #expect(AssignmentDisplay.label(for: "Amaya1", accountEmail: "", localName: "Amaya1", shared: false) == "Me")
        #expect(AssignmentDisplay.label(for: "Amayaa", accountEmail: "amaya@example.com", localName: "Amaya", shared: false) == "Me")
        #expect(AssignmentDisplay.label(for: "amaya@example.com", accountEmail: "amaya@example.com", localName: "Amaya", shared: false) == "Me")
    }
    @Test func taskFiltersClassifyPendingOverdueImportantAndCompleted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = HouseholdRecord(kind: .task, title: "Pending", date: now.addingTimeInterval(60))
        var overdue = HouseholdRecord(kind: .task, title: "Overdue", date: now.addingTimeInterval(-60))
        var important = HouseholdRecord(kind: .task, title: "Important", date: now.addingTimeInterval(60), important: true)
        var completed = HouseholdRecord(kind: .task, title: "Completed", date: now); completed.completed = true
        #expect(TaskFilter.pending.includes(pending, shared: false, accountEmail: "", localName: "Me", now: now))
        #expect(TaskFilter.overdue.includes(overdue, shared: false, accountEmail: "", localName: "Me", now: now))
        #expect(TaskFilter.important.includes(important, shared: false, accountEmail: "", localName: "Me", now: now))
        #expect(TaskFilter.completed.includes(completed, shared: false, accountEmail: "", localName: "Me", now: now))
        overdue.completed = true; important.completed = true
        #expect(!TaskFilter.overdue.includes(overdue, shared: false, accountEmail: "", localName: "Me", now: now))
        #expect(!TaskFilter.important.includes(important, shared: false, accountEmail: "", localName: "Me", now: now))
    }
}

struct SpendingTests {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func date(_ month: Int, day: Int = 10) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }
    @Test func paidBillsUsePaymentMonth() {
        let bill = HouseholdRecord(kind: .bill, title: "April bill", amount: 500, date: date(4), completed: true, paidAt: date(5))
        #expect(ExpenseIntelligence.spendingRecords([bill], inMonthOf: date(4), calendar: calendar).isEmpty)
        #expect(ExpenseIntelligence.spendingRecords([bill], inMonthOf: date(5), calendar: calendar).count == 1)
    }
    @Test func totalsExcludeUnpaidBillsAndTasks() {
        let records = [HouseholdRecord(kind: .expense, title: "Food", amount: 200, date: date(5)), HouseholdRecord(kind: .bill, title: "Paid", amount: 300, date: date(4), completed: true, paidAt: date(5)), HouseholdRecord(kind: .bill, title: "Unpaid", amount: 900, date: date(5)), HouseholdRecord(kind: .task, title: "Task", amount: 900, date: date(5))]
        #expect(ExpenseIntelligence.spendingRecords(records, inMonthOf: date(5), calendar: calendar).reduce(0) { $0 + $1.amount } == 500)
    }
    @Test func completedHistoryExcludesPartialCurrentMonth() throws {
        let records = (1...4).map { HouseholdRecord(kind: .expense, title: "Monthly", amount: Double($0 * 100), date: date($0)) }
        #expect(try ExpenseIntelligence.completedMonthTotals(records: records, now: date(4), calendar: calendar) == [100, 200, 300])
    }
    @Test func insufficientHistoryThrows() {
        #expect(throws: (any Error).self) { try ExpenseIntelligence.completedMonthTotals(records: [], now: date(4), calendar: calendar) }
    }
    @Test func zeroMonthIsInsufficient() {
        let records = (1...3).map { HouseholdRecord(kind: .expense, title: "Monthly", amount: $0 == 2 ? 0 : 100, date: date($0)) }
        #expect(throws: (any Error).self) { try ExpenseIntelligence.completedMonthTotals(records: records, now: date(4), calendar: calendar) }
    }
    @Test func anomalyNeedsHistoryAndThreshold() {
        let history = (1...3).map { HouseholdRecord(kind: .expense, title: "Food", amount: 100, date: date($0), category: "Groceries") }
        let current = HouseholdRecord(kind: .expense, title: "Food", amount: 151, date: date(4), category: "Groceries")
        #expect(ExpenseIntelligence.spendingAlerts(records: history + [current], now: date(4), calendar: calendar).count == 1)
        #expect(ExpenseIntelligence.spendingAlerts(records: [current], now: date(4), calendar: calendar).isEmpty)
    }
    @Test func monthNavigationClampsDay() {
        let january = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        let february = CalendarMonth(date: january, calendar: calendar).moving(1, preserving: january)
        #expect(calendar.component(.day, from: february) == 28)
    }
}

@MainActor
struct PersistenceTests {
    @Test func privateNoticesAddEditDeleteWithoutReplacingOthers() async throws {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.guestSessionActive = true
        var preferences = store.preferences
        preferences.bulletinTitle = "Existing"; preferences.bulletinBody = "Keep this notice"
        #expect(store.updatePreferences(preferences))
        let model = CommunicationViewModel(store: store, account: CloudAccount(), family: nil, context: nil)
        var notice = FamilyAnnouncement(title: "New", body: "Second notice", authorID: "guest", authorName: "Me")
        try await model.saveAnnouncement(notice)
        #expect(model.orderedAnnouncements.count == 2)
        #expect(store.preferences.bulletinTitle == "New")
        notice.title = "Edited"
        try await model.saveAnnouncement(notice)
        #expect(model.orderedAnnouncements.count == 2)
        #expect(store.preferences.bulletinTitle == "Edited")
        let loaded = HouseholdStore(storageURL: url, notificationsEnabled: false)
        #expect(loaded.preferences.resolvedPrivateNotices.count == 2)
        await model.deleteAnnouncement(notice)
        #expect(model.orderedAnnouncements.count == 1)
        #expect(store.preferences.bulletinTitle == "Existing")
        store.activate(userID: "another-account")
        #expect(store.preferences.resolvedPrivateNotices.isEmpty)
    }

    @Test func privateNoticeUsesExistingDashboardBulletin() async throws {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.guestSessionActive = true
        let account = CloudAccount()
        let model = CommunicationViewModel(store: store, account: account, family: nil, context: nil)
        var notice = FamilyAnnouncement(authorID: "guest", authorName: "Me")
        notice.title = "Water cut"; notice.body = "Fill the water tank tonight."
        try await model.saveAnnouncement(notice)
        #expect(store.preferences.bulletinTitle == notice.title)
        #expect(store.preferences.bulletinBody == notice.body)
        #expect(model.hasAnnouncement)
        #expect(model.announcements.isEmpty)
        let reloaded = HouseholdStore(storageURL: url, notificationsEnabled: false)
        #expect(reloaded.preferences.bulletinTitle == notice.title)
    }

    @Test func dashboardUsesMeForLegacyPrivateAssignments() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let model = DashboardViewModel(store: store, account: CloudAccount())
        for kind in [RecordKind.task, .bill, .maintenance, .event] {
            for assignee in ["Amayaa", "Me", "amaya@example.com"] {
                let record = HouseholdRecord(kind: kind, title: "Activity", assignee: assignee)
                #expect(model.assigneeLabel(record) == "Me")
                #expect(record.assignee == assignee)
            }
        }
    }

    @Test func historicalExpenseEditorPreservesDateAndPersistsMonthlySpending() async throws {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.guestSessionActive = true
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Colombo"))
        for month in [8, 9, 10] {
            let date = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: 5, hour: 12)))
            let record = HouseholdRecord(kind: .expense, title: "Historical expense", amount: Double(month)*1000, date: date, category: "Groceries")
            #expect(store.upsert(record))
            let editor = RecordEditorViewModel(store: store, account: CloudAccount(), record: record, sharedMembers: nil, onSave: nil)
            #expect(editor.record.date == date)
            #expect(editor.validationError == nil)
            editor.record.title = "Edited historical expense"
            #expect(await editor.save())
            let saved = try #require(store.records.first { $0.id == record.id })
            #expect(saved.date == date)
            let decoded = try FirestoreRecordCodec.decode(FirestoreRecordCodec.encode(saved))
            #expect(decoded.date == date)
            #expect(ExpenseIntelligence.spendingRecords(store.records, inMonthOf: date, calendar: calendar).reduce(0) { $0 + $1.amount } == Double(month)*1000)
        }
        let november = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(try ExpenseIntelligence.completedMonthTotals(records: store.records, now: november, calendar: calendar) == [8000, 9000, 10000])
        let reloaded = HouseholdStore(storageURL: url, notificationsEnabled: false)
        #expect(reloaded.records.map(\.date).sorted() == store.records.map(\.date).sorted())
        let newExpense = HouseholdRecord(kind: .expense, title: "")
        let newEditor = RecordEditorViewModel(store: store, account: CloudAccount(), record: newExpense, sharedMembers: nil, onSave: nil)
        #expect(Calendar.current.isDateInToday(newEditor.record.date))
        newEditor.record.title = "Tomorrow expense"
        newEditor.record.date = Date().addingTimeInterval(172800)
        #expect(newEditor.validationError != nil)
        #expect(await newEditor.save() == false)
    }

    @Test func categoryFeedbackIsAggregatePersistentAndAccountScoped() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.recordCategoryCorrection(predicted: "Other", selected: "Health", expectedScope: "guest")
        #expect(store.categoryCorrections == ["Other → Health": 1])
        store.activate(userID: "second")
        #expect(store.categoryCorrections.isEmpty)
        store.recordCategoryCorrection(predicted: "Other", selected: "Health", expectedScope: "guest")
        #expect(store.categoryCorrections.isEmpty)
        store.activate(userID: nil)
        #expect(store.categoryCorrections == ["Other → Health": 1])
        let reloaded = HouseholdStore(storageURL: url, notificationsEnabled: false)
        #expect(reloaded.categoryCorrections == ["Other → Health": 1])
    }
    @Test func correctedOCRCategorySurvivesEditorTitleChanges() async {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.guestSessionActive = true
        let draft = HouseholdRecord(kind: .expense, title: "Scanned receipt", amount: 500, category: "Home")
        let editor = RecordEditorViewModel(store: store, account: CloudAccount(), record: draft, sharedMembers: nil, onSave: nil)
        editor.record.title = "Medical report"
        await editor.suggestAfterTitleChange()
        #expect(editor.record.category == "Home")
    }

    @Test func automaticExpenseCategoryPreservesManualChoice() async {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.guestSessionActive = true
        let model = RecordEditorViewModel(store: store, account: CloudAccount(), record: HouseholdRecord(kind: .expense, title: "Medical report"), sharedMembers: nil, onSave: nil)
        await model.suggestAfterTitleChange()
        #expect(model.record.category == "Health")
        model.chooseCategory("Home")
        model.record.title = "Blood test"
        await model.suggestAfterTitleChange()
        #expect(model.record.category == "Home")
    }

    @Test func budgetWarningsDistinguishPredictionAndRecordedSpending() async {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let account = CloudAccount(), context = HouseholdContext(account: CloudAccount())
        var preferences = store.preferences; preferences.monthlyBudget = 500
        #expect(store.updatePreferences(preferences))
        for offset in [-3, -2, -1] {
            let date = Calendar.current.date(byAdding: .month, value: offset, to: Calendar.current.startOfDay(for: Date()))!
            #expect(store.upsert(HouseholdRecord(kind: .expense, title: "History", amount: 1000, date: date)))
        }
        let model = AnalyticsViewModel(store: store, account: account, context: context)
        await model.analyse()
        #expect(model.budgetWarning?.contains("Core ML estimates") == true)
        #expect(store.upsert(HouseholdRecord(kind: .expense, title: "Current", amount: 600)))
        #expect(model.budgetWarning?.contains("Recorded spending") == true)
        context.select(SharedFamily(id: "shared", name: "Family", ownerID: "owner", currency: "LKR"))
        let shared = AnalyticsViewModel(store: store, account: account, context: context)
        await shared.analyse()
        #expect(shared.budgetWarning == nil)
    }
    @Test func expenseAnalysisDoesNotLeakAcrossHouseholdSwitch() async {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let account = CloudAccount(), context = HouseholdContext(account: CloudAccount())
        #expect(store.upsert(HouseholdRecord(kind: .expense, title: "Private purchase", amount: 500)))
        let privateModel = AnalyticsViewModel(store: store, account: account, context: context)
        await privateModel.analyse()
        #expect(privateModel.analysis != nil)
        context.select(SharedFamily(id: "family-a", name: "A", ownerID: "owner", currency: "LKR"))
        #expect(privateModel.analysis == nil)
        let sharedModel = AnalyticsViewModel(store: store, account: account, context: context)
        await sharedModel.analyse()
        #expect(sharedModel.currentTotal == 0)
        #expect(sharedModel.analysis?.anomalies.recentCount == 0)
        #expect(store.records.count == 1)
        context.select(SharedFamily(id: "family-b", name: "B", ownerID: "owner", currency: "LKR"))
        #expect(sharedModel.analysis == nil)
    }
    @Test func OCRCorrectionKeepsManuallySelectedCategory() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let scanner = ScannerViewModel(store: store, account: CloudAccount(), initialKind: .expense)
        scanner.selectCategory("Health")
        scanner.applyEditedText("Supermarket\nTotal 1500.00")
        #expect(scanner.category == "Health")
        #expect(scanner.categoryWasEdited)
    }
    @Test func allHouseholdsDeduplicatesBySourceWithoutCopyingPrivateData() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let record = HouseholdRecord(kind: .task, title: "Private")
        #expect(store.upsert(record))
        let family = SharedFamily(id: "family", name: "Family", ownerID: "owner", currency: "LKR")
        let privateEntry = AccessibleRecord(record: record, family: nil, members: [])
        let sharedEntry = AccessibleRecord(record: record, family: family, members: [])
        #expect(AccessibleRecord.unique([privateEntry, sharedEntry, sharedEntry]).count == 2)
        let model = AccessibleRecordsViewModel(store: store, account: CloudAccount())
        #expect(model.filtered(kind: .task, date: nil).count == 1)
        #expect(model.filtered(kind: .bill, date: nil).isEmpty)
        #expect(store.records.count == 1)
        #expect(model.entries.first?.family == nil)
    }
    @Test func privateVisibilityPreservesAllRecordFieldsAndEditsInPlace() async {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        for kind in [RecordKind.bill, .maintenance, .event, .expense] {
            var record = HouseholdRecord(kind: kind, title: "Original", amount: 1234, date: Date().addingTimeInterval(7200))
            record.notes = "OCR and notes"; record.referenceNumber = "REF-123"
            record.reminderDate = record.date.addingTimeInterval(-3600)
            if kind == .bill { record.completed = true }
            let model = RecordEditorViewModel(store: store, account: CloudAccount(), record: record, sharedMembers: nil, onSave: nil)
            #expect(model.taskVisibility == .privateTask)
            #expect(await model.save())
            let saved = try? #require(store.records.first(where: { $0.id == record.id }))
            #expect(saved?.amount == 1234)
            #expect(saved?.referenceNumber == "REF-123")
            #expect(saved?.reminderDate == record.reminderDate)
            if kind == .bill { #expect(saved?.paidAt != nil) }
            let editor = RecordEditorViewModel(store: store, account: CloudAccount(), record: saved ?? record, sharedMembers: nil, onSave: nil)
            editor.changeVisibility(.shared)
            #expect(editor.taskVisibility == .privateTask)
            editor.record.title = "Edited"
            #expect(await editor.save())
            #expect(store.records.filter { $0.id == record.id }.count == 1)
        }
    }
    @Test func sharedChatCanLoadFromPrivateContextWithoutChangingStorage() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VisibilityHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let account = CloudAccount(apiKey: "fixture", projectID: "fixture", session: session, storage: VisibilityMemorySession())
        account.email = "member@example.test"; account.password = "fixture-password"
        #expect(await account.authenticate(register: false))
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.activate(userID: account.userID)
        let context = HouseholdContext(account: account)
        await context.refresh()
        let family = try #require(context.families.first)
        let chat = SharedFamilyChatViewModel(store: store, account: account, family: family, context: context)
        await chat.load()
        #expect(chat.error == nil)
        #expect(context.family == nil)
        #expect(chat.family.id == family.id)
        #expect(store.messages.isEmpty)
        context.select(family)
        #expect(!chat.isActive)
    }

    @Test func householdRefreshReplacesStaleNameWithoutSwitchingScope() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VisibilityHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let account = CloudAccount(apiKey: "fixture", projectID: "fixture", session: session, storage: VisibilityMemorySession())
        account.email = "member@example.test"; account.password = "fixture-password"
        #expect(await account.authenticate(register: false))
        let context = HouseholdContext(account: account)
        context.select(SharedFamily(id: "chosen", name: "Old family name", ownerID: "member", currency: "LKR"))
        let identity = context.identity
        await context.refresh()
        #expect(context.error == nil)
        #expect(context.family?.name == "Chosen family")
        #expect(context.identity == identity)
        #expect(context.members.count == 1)
        context.select(nil)
        await context.refresh()
        #expect(context.family == nil)
        #expect(context.members.isEmpty)
        #expect(context.families.first?.name == "Chosen family")
    }

    @Test func sharedVisibilityUsesSelectedFirebaseHouseholdForEachKind() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VisibilityHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let account = CloudAccount(apiKey: "fixture", projectID: "fixture", session: session, storage: VisibilityMemorySession())
        account.email = "member@example.test"; account.password = "fixture-password"
        #expect(await account.authenticate(register: false))
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.activate(userID: account.userID)
        for kind in [RecordKind.bill, .maintenance, .event, .expense] {
            let model = RecordEditorViewModel(store: store, account: account,
                record: HouseholdRecord(kind: kind, title: "Shared", amount: 100), sharedMembers: nil, onSave: nil)
            await model.prepareEditor()
            #expect(model.sharedAvailable)
            #expect(model.taskHouseholds.map(\.id) == ["chosen"])
            model.changeVisibility(.shared)
            await model.loadTaskMembers()
            #expect(model.taskHouseholdID == "chosen")
            #expect(model.record.assignee == (kind == .event ? "Everyone" : "member@example.test"))
            #expect(model.validationError == nil)
            #expect(await model.save())
            #expect(store.records.isEmpty)
            model.changeVisibility(.privateTask)
            #expect(model.sharedMembers == nil)
            #expect(model.record.assignee == "Me")
        }
    }
    @Test func visibilitySwitchClearsSharedAssignmentAndSavesPrivateLocally() async {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let account = CloudAccount()
        let context = HouseholdContext(account: account)
        context.select(SharedFamily(id: "family", name: "Family", ownerID: "owner", currency: "LKR"))
        var sharedSaveCalled = false
        let model = RecordEditorViewModel(store: store, account: account,
            record: HouseholdRecord(kind: .task, title: "My task", assignee: "sandaru@example.test"),
            sharedMembers: [], onSave: { _ in sharedSaveCalled = true }, context: context)
        #expect(model.taskVisibility == .shared)
        model.changeVisibility(.privateTask)
        #expect(model.record.assignee == "Me")
        #expect(model.sharedMembers == nil)
        #expect(model.taskSaveTitle == "Create Private Task")
        #expect(await model.save())
        #expect(!sharedSaveCalled)
        #expect(store.records.first?.assignee == "Me")
        #expect(context.records.isEmpty)
    }
    @Test func sharedTaskDoesNotFallBackToPrivateStorage() async {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let model = RecordEditorViewModel(store: store, account: CloudAccount(),
            record: HouseholdRecord(kind: .task, title: "Family task"), sharedMembers: nil, onSave: nil)
        model.changeVisibility(.shared)
        #expect(!model.sharedAvailable)
        #expect(model.taskVisibility == .privateTask)
        #expect(model.record.assignee == "Me")
        #expect(store.records.isEmpty)
        model.changeVisibility(.privateTask)
        #expect(model.validationError == nil)
    }
    @Test func editingPrivateTaskUpdatesOriginalRecord() async {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let original = HouseholdRecord(kind: .task, title: "Original")
        #expect(store.upsert(original))
        let model = RecordEditorViewModel(store: store, account: CloudAccount(), record: original, sharedMembers: nil, onSave: nil)
        #expect(model.existingTask)
        model.record.title = "Updated"
        #expect(await model.save())
        #expect(store.records.count == 1)
        #expect(store.records.first?.id == original.id)
        #expect(store.records.first?.title == "Updated")
    }
    @Test func eachActivityModuleOnlyListsItsOwnRecords() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let account = CloudAccount()
        for kind in RecordKind.allCases {
            var record = HouseholdRecord(kind: kind, title: kind.rawValue, amount: 100)
            if kind == .bill { record.completed = true; record.paidAt = Date() }
            #expect(store.upsert(record))
        }
        for kind in RecordKind.allCases {
            let model = RecordsViewModel(store: store, account: account, kind: kind)
            #expect(model.filtered.count == 1)
            #expect(model.filtered.allSatisfy { $0.kind == kind })
        }
    }
    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("HomeMateTests-\(UUID()).sqlite") }
    private func cleanup(_ url: URL) { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
    @Test func recordSurvivesStoreRecreation() {
        let url = temporaryURL(); defer { cleanup(url) }
        let id = UUID()
        do {
            let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
            #expect(store.upsert(HouseholdRecord(id: id, kind: .task, title: "Persist me")))
        }
        let restored = HouseholdStore(storageURL: url, notificationsEnabled: false)
        #expect(restored.records.map(\.id) == [id])
    }
    @Test func completingAndReopeningBill() throws {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let bill = HouseholdRecord(kind: .bill, title: "Electricity", amount: 100)
        #expect(store.upsert(bill))
        store.toggle(bill)
        let paid = try #require(store.records.first)
        #expect(paid.completed && paid.paidAt != nil)
        store.toggle(paid)
        #expect(store.records.first?.completed == false)
        #expect(store.records.first?.paidAt == nil)
    }
    @Test func staleCompletionDoesNotUndoOrResurrect() throws {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let task = HouseholdRecord(kind: .task, title: "Clean")
        #expect(store.upsert(task)); store.toggle(task); store.toggle(task)
        #expect(store.records.first?.completed == true)
        store.delete(try #require(store.records.first)); store.toggle(task)
        #expect(store.records.isEmpty)
    }
    @Test func accountAndGuestIsolation() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        #expect(store.upsert(HouseholdRecord(kind: .task, title: "Guest")))
        store.activate(userID: "sarah")
        #expect(store.records.isEmpty)
        #expect(store.upsert(HouseholdRecord(kind: .task, title: "Sarah")))
        store.activate(userID: "nimal"); #expect(store.records.isEmpty)
        #expect(!store.replaceRecords([], expectedScope: "user:sarah"))
        store.activate(userID: "sarah"); #expect(store.records.first?.title == "Sarah")
        store.activate(userID: nil); #expect(store.records.first?.title == "Guest")
    }
    @Test func invalidWritePreservesRecords() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        #expect(store.upsert(HouseholdRecord(kind: .task, title: "Valid")))
        #expect(!store.upsert(HouseholdRecord(kind: .task, title: "")))
        #expect(store.records.count == 1)
    }
    @Test func recommendationCountsOpenWork() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.profile.members = "Sarah,Nimal"
        #expect(store.upsert(HouseholdRecord(kind: .task, title: "Clean", assignee: "Sarah")))
        #expect(store.recommendedMember == "Nimal")
    }
    @Test func currencyFormattingDoesNotConvert() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        store.profile.currency = "USD"
        #expect(store.money(123.45) == 123.45.formatted(.currency(code: "USD")))
    }
    @Test func registrationValidation() {
        let url = temporaryURL(); defer { cleanup(url) }
        let account = CloudAccount()
        let model = LoginViewModel(store: HouseholdStore(storageURL: url, notificationsEnabled: false), account: account)
        model.registering = true; account.email = "person@example.com"; account.password = "123456"
        model.confirmation = "mismatch"; #expect(!model.valid)
        model.confirmation = "123456"; #expect(model.valid)
        account.email = "invalid"; #expect(!model.valid)
    }
    @Test func selectedFamilyDoesNotExposePrivateTotals() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        #expect(store.upsert(HouseholdRecord(kind: .expense, title: "Private purchase", amount: 500)))
        let account = CloudAccount(), context = HouseholdContext(account: CloudAccount())
        let privateModel = DashboardViewModel(store: store, account: account, context: context)
        #expect(privateModel.spending == 500)
        context.select(SharedFamily(id: "family-a", name: "Family A", ownerID: "owner", currency: "USD"))
        #expect(!privateModel.isActive)
        let sharedModel = DashboardViewModel(store: store, account: account, context: context)
        #expect(sharedModel.spending == 0)
        #expect(sharedModel.activeRecords.isEmpty)
        #expect(sharedModel.profile.currency == "USD")
        #expect(sharedModel.preferences.monthlyBudget == 0)
        context.select(nil)
        #expect(!sharedModel.isActive)
        #expect(store.records.count == 1)
    }
    @Test func staleFamilySaveIsRejectedBeforeNetwork() async {
        let account = CloudAccount(), context = HouseholdContext(account: CloudAccount())
        context.select(SharedFamily(id: "a", name: "A", ownerID: "owner", currency: "LKR"))
        let original = context.identity
        context.select(SharedFamily(id: "b", name: "B", ownerID: "owner", currency: "LKR"))
        await #expect(throws: (any Error).self) {
            try await context.save(HouseholdRecord(kind: .task, title: "Wrong household"), expectedIdentity: original)
        }
        #expect(context.family?.id == "b")
        #expect(context.records.isEmpty)
        #expect(account.signedIn == false)
    }
    @Test func sharedEditorShowsMemberNamesAndRejectsHouseholdSwitch() {
        let url = temporaryURL(); defer { cleanup(url) }
        let store = HouseholdStore(storageURL: url, notificationsEnabled: false)
        let account = CloudAccount()
        account.email = "amaya@example.test"
        let context = HouseholdContext(account: account)
        context.select(SharedFamily(id: "family", name: "Family", ownerID: "owner", currency: "LKR"))
        let members = [
            FamilyMember(id: "owner", email: "amaya@example.test", displayName: "Amaya", role: "owner"),
            FamilyMember(id: "member", email: "sandaru@example.test", displayName: "Sandaru", role: "member")
        ]
        let model = RecordEditorViewModel(store: store, account: account,
            record: HouseholdRecord(kind: .task, title: "Clean kitchen", assignee: "sandaru@example.test"),
            sharedMembers: members, onSave: { _ in }, context: context)
        #expect(Set(model.assigneeOptions.map(\.title)) == Set(["Me", "Sandaru"]))
        #expect(model.assigneeOptions.first(where: { $0.title == "Sandaru" })?.id == "sandaru@example.test")
        context.select(nil)
        #expect(!model.isActive)
        #expect(model.validationError != nil)
    }
    @Test func announcementValidation() {
        var notice = FamilyAnnouncement(authorID: "owner", authorName: "Sarah")
        #expect(notice.validationError != nil)
        notice.title = "Water outage"; notice.body = "Tomorrow at noon"
        #expect(notice.validationError == nil)
        notice.body = String(repeating: "a", count: 10001)
        #expect(notice.validationError != nil)
    }
    @Test func importantAnnouncementsAppearBeforeNewerRegularNotices() {
        var regular = FamilyAnnouncement(authorID: "nimal", authorName: "Nimal")
        regular.title = "Sunday outing"; regular.body = "Meet at 9"; regular.createdAt = Date()
        var pinned = FamilyAnnouncement(authorID: "sarah", authorName: "Sarah")
        pinned.title = "Water cut"; pinned.body = "Store water"; pinned.important = true
        pinned.createdAt = Date().addingTimeInterval(-3_600)
        let ordered = FamilyAnnouncement.ordered([regular, pinned])
        #expect(ordered.map(\.id) == [pinned.id, regular.id])
    }
}

/// Tests use real bundled inference and deterministic history; no production data or network.
struct ExpenseIntelligenceTests {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))! }
    private var history: [HouseholdRecord] {
        (1...30).map { i in
            HouseholdRecord(kind: .expense, title: "Payment \(i)", amount: 90 + Double(i % 5) * 5,
                date: calendar.date(byAdding: .day, value: -i * 3, to: now)!, category: "Groceries")
        }
    }
    @Test func featuresExcludeTargetFutureAndDuplicateIDs() throws {
        let record = HouseholdRecord(kind: .expense, title: "Large shop", amount: 900, date: now, category: "Groceries")
        let future = HouseholdRecord(kind: .expense, title: "Future", amount: 99999, date: now.addingTimeInterval(86400), category: "Groceries")
        let a = try ExpenseIntelligence.anomalyFeatures(for: record, history: history, calendar: calendar)
        let b = try ExpenseIntelligence.anomalyFeatures(for: record, history: history + history + [record, future], calendar: calendar)
        #expect(a.sampleCount == 30)
        #expect(a.amountRatio == b.amountRatio)
        #expect(a.baseline == b.baseline)
        #expect(a.categoryFrequency == 1)
    }
    @Test func insufficientAndInvalidFeaturesAreRejected() {
        var record = HouseholdRecord(kind: .expense, title: "Shop", amount: 900, date: now, category: "Groceries")
        #expect(throws: (any Error).self) { try ExpenseIntelligence.anomalyFeatures(for: record, history: Array(history.prefix(5)), calendar: calendar) }
        record.amount = .nan
        #expect(throws: (any Error).self) { try ExpenseIntelligence.anomalyFeatures(for: record, history: history, calendar: calendar) }
        record.amount = 900; record.category = "Unknown"
        #expect(throws: (any Error).self) { try ExpenseIntelligence.anomalyFeatures(for: record, history: history, calendar: calendar) }
    }
    @Test func bundledModelScoresActualFeaturesAndFallbackIsLabelled() throws {
        let model = try #require(ExpenseIntelligence.anomalyModel)
        let normal = HouseholdRecord(kind: .expense, title: "Normal shop", amount: 100, date: now, category: "Groceries")
        var unusual = normal; unusual.amount = 900
        let low = try ExpenseIntelligence.anomalyScore(ExpenseIntelligence.anomalyFeatures(for: normal, history: history, calendar: calendar), model: model)
        let high = try ExpenseIntelligence.anomalyScore(ExpenseIntelligence.anomalyFeatures(for: unusual, history: history, calendar: calendar), model: model)
        #expect(low < ExpenseIntelligence.anomalyThreshold)
        #expect(high >= ExpenseIntelligence.anomalyThreshold)
        let report = ExpenseIntelligence.unusualTransactions(records: history + [unusual], now: now, calendar: calendar, model: model)
        #expect(report.transactions.contains { $0.id == unusual.id && $0.isML })
        let fallback = ExpenseIntelligence.unusualTransactions(records: history + [unusual], now: now, calendar: calendar, model: nil)
        #expect(fallback.unavailable)
        #expect(fallback.transactions.contains { $0.id == unusual.id && !$0.isML })
    }
    @Test func normalisedFeaturesAreCurrencyScaleInvariant() throws {
        let record = HouseholdRecord(kind: .expense, title: "Shop", amount: 500, date: now, category: "Groceries")
        var scaled = record; scaled.amount *= 100
        let scaledHistory = history.map { item in var item = item; item.amount *= 100; return item }
        let a = try ExpenseIntelligence.anomalyFeatures(for: record, history: history, calendar: calendar)
        let b = try ExpenseIntelligence.anomalyFeatures(for: scaled, history: scaledHistory, calendar: calendar)
        #expect(abs(a.amountRatio-b.amountRatio) < 0.000001)
        #expect(abs(a.deviation-b.deviation) < 0.000001)
    }
    @Test func paidBillAndExplicitExpenseDuplicateCountOnce() {
        let bill = HouseholdRecord(kind: .bill, title: "Water", amount: 500, date: now.addingTimeInterval(-86400), completed: true, referenceNumber: "REF123", paidAt: now)
        let expense = HouseholdRecord(kind: .expense, title: "Water", amount: 500, date: now, referenceNumber: "REF123")
        let another = HouseholdRecord(kind: .expense, title: "Water", amount: 500, date: now)
        let records = ExpenseIntelligence.spendingRecords([bill, bill, expense, another], inMonthOf: now, calendar: calendar)
        #expect(records.count == 2)
        #expect(records.reduce(0) { $0 + $1.amount } == 1000)
        #expect(records.contains { $0.id == bill.id })
        #expect(records.contains { $0.id == another.id })
    }
    @Test func calculatedPatternsUseCompletedMonthsAndDetectRecurringCosts() {
        let records = (7...9).map { month in
            HouseholdRecord(kind: .expense, title: "Internet", amount: 100, date: calendar.date(from: DateComponents(year: 2026, month: month, day: 10))!, category: "Utilities")
        }
        let partial = HouseholdRecord(kind: .expense, title: "Internet", amount: 9999, date: now, category: "Utilities")
        let patterns = ExpenseIntelligence.patterns(records: records, now: now, calendar: calendar)
        #expect(patterns.contains { $0.id.hasPrefix("recurring-") })
        let withPartial = ExpenseIntelligence.patterns(records: records + [partial], now: now, calendar: calendar)
        #expect(withPartial.first { $0.id == "trend-Utilities" }?.title == patterns.first { $0.id == "trend-Utilities" }?.title)
    }
    @Test func historicalForecastReplayDoesNotUseTargetOrFutureAsInputs() throws {
        let records = (6...9).map { month in
            HouseholdRecord(kind: .expense, title: "Monthly", amount: Double(month)*100, date: calendar.date(from: DateComponents(year: 2026, month: month, day: 10))!)
        }
        let first = try #require(ExpenseIntelligence.forecastComparisons(records: records, now: now, calendar: calendar).last)
        var changed = records; changed[3].amount = 99999
        let second = try #require(ExpenseIntelligence.forecastComparisons(records: changed, now: now, calendar: calendar).last)
        #expect(first.estimate == second.estimate)
        #expect(first.actual != second.actual)
    }
}

struct ErrandMonitoringTests {
    @Test func scopesKeepIdenticalRecordIDsSeparateAndRespectDeviceLimit() {
        let record = HouseholdRecord(kind: .task, title: "Place")
        let privateKey = "user:a:private", sharedKey = "user:a:family"
        let scopes = [privateKey: [record], sharedKey: [record]]
        let preferences = [privateKey + ":" + record.id.uuidString: 100.0, sharedKey + ":" + record.id.uuidString: 200.0]
        #expect(ErrandRegionPolicy.candidates(scopes: scopes, preferences: preferences, otherCount: 18).count == 2)
        #expect(ErrandRegionPolicy.candidates(scopes: scopes, preferences: preferences, otherCount: 19).count == 1)
        #expect(ErrandRegionPolicy.candidates(scopes: scopes, preferences: preferences, otherCount: 20).isEmpty)
        #expect(ErrandRegionPolicy.candidates(scopes: ["user:b:private": [record]], preferences: preferences, otherCount: 0).isEmpty)
    }
    @Test func removedRecordsAndInvalidPreferencesDoNotMonitor() {
        let record = HouseholdRecord(kind: .task, title: "Place")
        let key = "user:a:private"
        #expect(ErrandRegionPolicy.candidates(scopes: [:], preferences: [key + ":" + record.id.uuidString: 200], otherCount: 0).isEmpty)
        #expect(ErrandRegionPolicy.candidates(scopes: [key: [record]], preferences: [key + ":" + record.id.uuidString: .nan], otherCount: 0).isEmpty)
    }
}

struct ErrandMapVisibilityTests {
    @Test func typedAddressesRemainVisibleWithoutInventingPins() {
        var record = HouseholdRecord(kind: .task, title: "Shop")
        record.location = "Colombo"
        #expect(ErrandMapPolicy.isVisible(record, includeCompleted: false))
        #expect(!ErrandMapPolicy.hasPin(record))
        #expect(ErrandMapPolicy.directionsURL(record, google: true) == nil)
        record.completed = true
        #expect(!ErrandMapPolicy.isVisible(record, includeCompleted: false))
        #expect(ErrandMapPolicy.isVisible(record, includeCompleted: true))
    }
    @Test func directionsPreserveCoordinatesWithoutForcingTransport() throws {
        var record = HouseholdRecord(kind: .task, title: "Shop")
        record.latitude = 6.9271; record.longitude = 79.8612
        for google in [false, true] {
            let url = try #require(ErrandMapPolicy.directionsURL(record, google: google))
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.first { $0.name == (google ? "destination" : "daddr") }?.value == "6.9271,79.8612")
            #expect(!items.contains { $0.name == "dirflg" })
        }
    }
}

struct MedicalCategoryCorrectionTests {
    @Test func medicalReportsUseHealthWithoutMatchingUnrelatedReports() {
        #expect(ExpenseIntelligence.medicalCategoryCorrection("Medical report") == "Health")
        #expect(ExpenseIntelligence.medicalCategoryCorrection("Paid for BLOOD TEST") == "Health")
        #expect(ExpenseIntelligence.medicalCategoryCorrection("Annual report printing") == nil)
        #expect(ExpenseIntelligence.medicalCategoryCorrection("medical reporting software") == nil)
    }
}

struct ForecastAuditTests {
    @Test func invalidAndExtremeHistoriesFailSafely() throws {
        let model = try #require(ExpenseIntelligence.forecaster)
        for history in [[0.0, 10, 10], [Double.nan, 10, 10], [Double.infinity, 10, 10], [1e13, 1e13, 1e13]] {
            #expect(throws: (any Error).self) { try ExpenseIntelligence.predictMonth(history: history, model: model) }
        }
    }
    @Test func baselineUsesOnlyPrecedingMonths() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        let records = (6...9).map { month in HouseholdRecord(kind: .expense, title: "Expense", amount: Double(month)*100, date: calendar.date(from: DateComponents(year: 2026, month: month, day: 1))!) }
        let comparison = try #require(ExpenseIntelligence.forecastComparisons(records: records, now: now, calendar: calendar).last)
        #expect(comparison.baseline == 700)
        #expect(comparison.actual == 900)
    }
}

struct ExpenseDatePolicyTests {
    @Test func permitsEarlierYearsAndTodayButNotFutureDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Colombo"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 10)))
        var record = HouseholdRecord(kind: .expense, title: "Expense", date: now)
        for year in [2020, 2025, 2026] {
            record.date = try #require(calendar.date(from: DateComponents(year: year, month: 8, day: 1)))
            #expect(record.expenseDateError(now: now, calendar: calendar) == nil)
        }
        record.date = now.addingTimeInterval(3600)
        #expect(record.expenseDateError(now: now, calendar: calendar) == nil)
        record.date = now.addingTimeInterval(86400)
        #expect(record.expenseDateError(now: now, calendar: calendar) != nil)
        for kind in [RecordKind.bill, .task, .event, .maintenance] {
            record.kind = kind
            #expect(record.expenseDateError(now: now, calendar: calendar) == nil)
        }
    }
}
