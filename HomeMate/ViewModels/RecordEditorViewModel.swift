import Foundation
import Combine

@MainActor
final class RecordEditorViewModel: ScreenViewModel {
    @Published var cloudBusy = false
    @Published var cloudMessage = ""
    @Published var record: HouseholdRecord
    @Published var saving = false
    @Published var saveError: String?
    @Published private(set) var savedDestination: SharedFamily?
    @Published var categoryMessage: String?
    @Published var categoryFailed = false
    private var categoryChosenManually = false
    private var lastModelCategory: String?
    private var feedbackRecorded = false
    @Published var calendarDraft: CalendarEventDraft?
    @Published var calendarMessage: String?
    @Published var calendarFailed = false

    struct AssignmentOption: Identifiable, Hashable {
        let id: String
        let title: String
    }

    @Published private(set) var sharedMembers: [FamilyMember]?
    @Published private(set) var loadingMembers = false
    @Published private(set) var membersError: String?
    private let editingFamilyID: String?
    enum TaskVisibility: String, CaseIterable { case privateTask = "Private", shared = "Shared" }
    @Published private(set) var taskVisibility: TaskVisibility
    @Published private(set) var taskHouseholdID: String
    @Published private(set) var taskHouseholds: [SharedFamily] = []
    @Published private(set) var loadingHouseholds = false
    @Published private(set) var householdsError: String?
    private var memberRequest = UUID()
    let existingTask: Bool
    var isTask: Bool { record.kind == .task }
    var supportsAssignment: Bool { record.kind != .event }
    var recordName: String {
        switch record.kind {
        case .task: "Task"
        case .bill: "Bill"
        case .expense: "Expense"
        case .maintenance: "Maintenance"
        case .event: "Event"
        }
    }
    var sharedAvailable: Bool { accountSignedIn && !loadingHouseholds && !taskHouseholds.isEmpty && householdsError == nil }
    var taskSaveTitle: String { existingTask ? "Save \(recordName)" : "Create \(taskVisibility == .shared ? "Shared" : "Private") \(recordName)" }
    let onSave: ((HouseholdRecord) async throws -> Void)?
    init(store: HouseholdStore, account: CloudAccount, record: HouseholdRecord, sharedMembers: [FamilyMember]?, onSave: ((HouseholdRecord) async throws -> Void)?, context: HouseholdContext? = nil, sourceFamily: SharedFamily? = nil, correctedModelCategory: String? = nil) {
        var draft = record
        // A newly created activity should not become overdue while the user is
        // still filling in the form. Preserve dates chosen by Calendar and scans.
        if draft.title.isEmpty, draft.kind != .expense, abs(draft.date.timeIntervalSinceNow) < 10 {
            draft.date = Date().addingTimeInterval(3600)
        }
        // Preserve an existing non-default category, including a category the user
        // confirmed while reviewing a scanned receipt.
        categoryChosenManually = correctedModelCategory != nil || (!record.title.isEmpty && record.category != "Other")
        lastModelCategory = correctedModelCategory
        self.record = draft; self.sharedMembers = sharedMembers; self.onSave = onSave
        editingFamilyID = sourceFamily?.id ?? context?.family?.id
        taskVisibility = sharedMembers == nil ? .privateTask : .shared
        taskHouseholdID = editingFamilyID ?? ""
        existingTask = record.cloudRevision != nil || store.records.contains(where: { $0.id == record.id })
        super.init(store: store, account: account, context: context)
        if sharedMembers == nil { self.record.assignee = "Me" }
    }
    func prepareEditor() async {
        guard isActive, accountSignedIn, !loadingHouseholds else { return }
        loadingHouseholds = true; householdsError = nil
        defer { loadingHouseholds = false }
        do {
            let values = try await FamilyAPI(account: account).families()
            guard isActive, !Task.isCancelled else { return }
            taskHouseholds = values
            if taskVisibility == .shared {
                if taskHouseholdID.isEmpty && !existingTask { taskHouseholdID = values.first?.id ?? "" }
                await loadTaskMembers()
            }
        } catch { if isActive && !Task.isCancelled { householdsError = error.localizedDescription } }
    }
    func changeVisibility(_ value: TaskVisibility) {
        guard !existingTask, !saving, value != taskVisibility else { return }
        guard value != .shared || sharedAvailable else { return }
        taskVisibility = value
        invalidateTaskMembers()
        if value == .shared && taskHouseholdID.isEmpty { taskHouseholdID = taskHouseholds.first?.id ?? "" }
    }
    func selectTaskHousehold(_ id: String) {
        guard !existingTask, !saving, id != taskHouseholdID else { return }
        taskHouseholdID = id
        invalidateTaskMembers()
    }
    private func invalidateTaskMembers() {
        memberRequest = UUID(); loadingMembers = false; membersError = nil; saveError = nil
        sharedMembers = taskVisibility == .shared ? [] : nil
        record.assignee = taskVisibility == .shared ? "" : "Me"
    }
    func loadTaskMembers() async {
        guard taskVisibility == .shared, isActive else { return }
        let id = taskHouseholdID, request = UUID()
        memberRequest = request; sharedMembers = []; membersError = nil
        loadingMembers = true
        defer { if memberRequest == request { loadingMembers = false } }
        guard taskHouseholds.contains(where: { $0.id == id }) else { membersError = "Select a household you belong to."; return }
        do {
            let values = try await FamilyAPI(account: account).members(familyID: id)
            guard isActive, !Task.isCancelled, memberRequest == request, taskVisibility == .shared, taskHouseholdID == id else { return }
            sharedMembers = values
            if !supportsAssignment { record.assignee = "Everyone"; return }
            if !values.contains(where: { $0.email == record.assignee }) {
                record.assignee = values.first(where: { $0.email.caseInsensitiveCompare(account.email) == .orderedSame })?.email ?? values.first?.email ?? ""
            }
        } catch { if isActive && memberRequest == request && !Task.isCancelled { membersError = error.localizedDescription } }
    }
    func loadMembers() async {
        guard isActive, let editingFamilyID, !loadingMembers else { return }
        loadingMembers = true; membersError = nil
        defer { loadingMembers = false }
        do {
            let members = try await FamilyAPI(account: account).members(familyID: editingFamilyID)
            guard isActive, !Task.isCancelled else { return }
            sharedMembers = members
            if record.cloudRevision == nil, record.assignee != "Everyone",
               !members.contains(where: { $0.email.caseInsensitiveCompare(record.assignee) == .orderedSame }),
               let me = members.first(where: { $0.email.caseInsensitiveCompare(account.email) == .orderedSame }) {
                record.assignee = me.email
            }
        } catch {
            guard isActive, !Task.isCancelled else { return }
            sharedMembers = []
            membersError = "Could not load household members. " + error.localizedDescription
        }
    }
    var assigneeOptions: [AssignmentOption] {
        if taskVisibility == .privateTask { return [AssignmentOption(id: "Me", title: "Me (You)")] }
        if let sharedMembers {
            let people = sharedMembers
                .map { member in
                    AssignmentOption(
                        id: member.email,
                        title: AssignmentDisplay.label(for: member.email, accountEmail: account.email, localName: profile.name, members: sharedMembers, shared: true)
                    )
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return people
        }

        let candidates = profile.memberNames + [record.assignee, "Me"]
        var options: [AssignmentOption] = []
        var includedSelf = false
        for candidate in candidates {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let isSelf = value.caseInsensitiveCompare("Me") == .orderedSame || (!profile.name.isEmpty && value.caseInsensitiveCompare(profile.name) == .orderedSame)
            if isSelf {
                guard !includedSelf else { continue }
                let identifier = record.assignee.caseInsensitiveCompare("Me") == .orderedSame || (!profile.name.isEmpty && record.assignee.caseInsensitiveCompare(profile.name) == .orderedSame) ? record.assignee : value
                options.append(AssignmentOption(id: identifier, title: "Me"))
                includedSelf = true
            } else if !options.contains(where: { $0.id.caseInsensitiveCompare(value) == .orderedSame }) {
                options.append(AssignmentOption(id: value, title: value))
            }
        }
        if !includedSelf { options.insert(AssignmentOption(id: "Me", title: "Me"), at: 0) }
        return options.sorted { $0.title == "Me" ? true : $1.title == "Me" ? false : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    var validationError: String? {
        if taskVisibility == .shared {
            if !accountSignedIn { return "Sign in to create or edit a shared record." }
            if loadingHouseholds { return "Loading your households…" }
            if let householdsError { return householdsError }
            if !taskHouseholds.contains(where: { $0.id == taskHouseholdID }) { return "Select a household you belong to." }
            if supportsAssignment && !(sharedMembers ?? []).contains(where: { $0.email == record.assignee }) { return "Choose a member of the selected household." }
        }
        if loadingMembers { return "Loading household members…" }
        if let membersError { return membersError }
        if !isActive { return "The selected household changed. Close this editor and open it in the correct household." }
        if let problem = record.validationError ?? record.expenseDateError() { return problem }
        if let sharedMembers,
           record.assignee != "Everyone",
           !sharedMembers.contains(where: { $0.email.caseInsensitiveCompare(record.assignee) == .orderedSame }) {
            return "Choose an active member of this household, or Everyone."
        }
        return nil
    }
    var defaultReminderDate: Date? { ReminderSchedule.defaultDate(for: record) }
    func prepareCalendarExport() {
        guard isActive, !saving, calendarDraft == nil else { return }
        calendarMessage = nil
        calendarFailed = false
        do { calendarDraft = try CalendarExportService.draft(from: record) }
        catch { calendarFailed = true; calendarMessage = error.localizedDescription }
    }
    func completeCalendarExport(_ outcome: CalendarExportOutcome) {
        calendarDraft = nil
        guard isActive else { return }
        calendarFailed = false
        calendarMessage = outcome == .saved ? "Added to Apple Calendar. Save any changes in HomeMate separately." : nil
    }
    func chooseCategory(_ value: String) {
        categoryChosenManually = true
        record.category = value
        categoryMessage = "Your selected category will be kept."
        categoryFailed = false
    }
    func suggestAfterTitleChange() async {
        let title = record.title
        guard [.task, .bill, .expense, .maintenance].contains(record.kind),
              !categoryChosenManually, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
        guard !Task.isCancelled, isActive, !saving, record.title == title, !categoryChosenManually else { return }
        suggestCategory()
    }
    func suggestCategory() {
        do {
            let description = record.title + " " + record.notes
            let prediction = try ExpenseIntelligence.suggestCategory(description)
            lastModelCategory = prediction
            record.category = ExpenseIntelligence.medicalCategoryCorrection(description) ?? prediction
            categoryFailed = false
            categoryMessage = ExpenseIntelligence.medicalCategoryCorrection(record.title + " " + record.notes) != nil
                ? "Health suggested from the description. You can change it."
                : "Suggested \(record.category). Review and change it if needed."
        } catch { categoryFailed = true; categoryMessage = error.localizedDescription }
    }
    func uploadPrivateRecord() async {
        guard isActive, !cloudBusy, validationError == nil else { return }
        let scope = account.dataScope; let snapshot = normalizedRecord
        cloudBusy = true; defer { cloudBusy = false }
        do { try await FirebaseHouseholdAPI(account: account).save(snapshot); if isCurrent(scope) { cloudMessage = "Saved to your cloud account." } }
        catch { if isCurrent(scope) { cloudMessage = error.localizedDescription } }
    }
    private func recordCorrectionFeedback() {
        guard !feedbackRecorded, categoryChosenManually, let predicted = lastModelCategory, predicted != record.category else { return }
        store.recordCategoryCorrection(predicted: predicted, selected: record.category, expectedScope: accountDataScope)
        feedbackRecorded = true
    }
    func save() async -> Bool {
        guard isActive, !saving, validationError == nil else { return false }
        let scope = account.dataScope; let snapshot = normalizedRecord
        saving = true; saveError = nil; defer { saving = false }
        do {
            if ReminderSchedule.date(for: snapshot) != nil {
                try await store.prepareReminderPermission()
                guard isCurrent(scope) else { return false }
            }
            do {
                if taskVisibility == .privateTask {
                    let saved = store.upsert(snapshot)
                    if !saved { saveError = store.error }
                    if saved { recordCorrectionFeedback() }
                    return saved
                }
                if existingTask, let onSave { try await onSave(snapshot); if isCurrent(scope) { recordCorrectionFeedback() }; return isCurrent(scope) }
                let destination = taskHouseholdID
                try await FamilyAPI(account: account).save(snapshot, familyID: destination)
                guard isCurrent(scope) else { return false }
                if context?.family?.id == destination { await context?.refresh() }
                else if context != nil { savedDestination = taskHouseholds.first { $0.id == destination } }
                recordCorrectionFeedback()
                return true
            }
        } catch {
            if isCurrent(scope) { saveError = error.localizedDescription }
            return false
        }
    }

    private var normalizedRecord: HouseholdRecord {
        var value = record
        if value.reminderDate == nil {
            value.reminderDate = ReminderSchedule.date(for: value)
        }
        if taskVisibility == .privateTask { value.assignee = "Me" }
        else if !supportsAssignment { value.assignee = "Everyone" }
        if value.kind == .bill {
            if value.completed && value.paidAt == nil { value.paidAt = Date() }
            if !value.completed { value.paidAt = nil }
        }
        return value
    }

}

@MainActor
final class RecordDetailViewModel: ScreenViewModel {
    private let initialRecord: HouseholdRecord

    init(store: HouseholdStore, account: CloudAccount, record: HouseholdRecord, context: HouseholdContext? = nil) {
        initialRecord = record
        super.init(store: store, account: account, context: context)
    }

    var record: HouseholdRecord {
        activeRecords.first(where: { $0.id == initialRecord.id }) ?? initialRecord
    }
    var assigneeLabel: String {
        AssignmentDisplay.label(for: record.assignee, accountEmail: account.email, localName: profile.name, members: context?.members ?? [], shared: context?.family != nil)
    }
    var isOverdue: Bool { !record.completed && record.kind != .expense && record.date < Date() }
    var statusTitle: String {
        if record.kind == .expense { return "Recorded" }
        if record.kind == .bill { return record.completed ? "Paid" : "Unpaid" }
        if record.completed { return "Completed" }
        return isOverdue ? "Overdue" : "Pending"
    }
    var completionAction: String {
        if record.completed { return "Reopen" }
        return record.kind == .bill ? "Mark as paid" : "Mark complete"
    }
    var recommendation: String {
        if record.kind == .expense { return "This purchase is included in spending for its purchase month." }
        if record.completed { return "This activity is complete. Reopen it if more work is needed." }
        if record.date < Date() { return "This activity is overdue. Review it and update the status or due date." }
        if record.date.timeIntervalSinceNow < 86_400 { return "This activity is due within 24 hours. It may need your attention soon." }
        if record.important { return "This activity is marked important. Keep its due date and assignee in view." }
        return "Everything is on track. HomeMate will keep this activity in your upcoming plan."
    }
    var reminderDescription: String {
        guard record.kind != .expense else { return "No reminder for expenses" }
        guard preferencesEnabled else { return "Household reminders are turned off" }
        guard record.reminderEnabled != false else { return "Reminder is off for this activity" }
        if record.completed { return "No reminder for completed activities" }
        if record.date <= Date() { return "Due date has passed" }
        if let reminderDate = ReminderSchedule.date(for: record) {
            return reminderDate.formatted(date: .abbreviated, time: .shortened)
        }
        return "No reminder scheduled"
    }
    private var preferencesEnabled: Bool { profile.reminders }

    func toggleCompletion() { toggle(record) }
    func remove() { delete(record) }
}
