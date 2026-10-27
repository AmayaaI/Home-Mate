import Foundation
import Combine

struct AccessibleRecord: Identifiable {
    let record: HouseholdRecord
    let family: SharedFamily?
    let members: [FamilyMember]
    var id: String { (family?.id ?? "private") + ":" + record.id.uuidString }
    var householdName: String { family?.name ?? "Private" }
    static func unique(_ values: [AccessibleRecord]) -> [AccessibleRecord] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }
}

@MainActor
final class AccessibleRecordsViewModel: ScreenViewModel {
    @Published private(set) var shared: [AccessibleRecord] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var mineOnly = false
    @Published var pendingOnly = false
    var entries: [AccessibleRecord] {
        AccessibleRecord.unique(personalRecords.map { AccessibleRecord(record: $0, family: nil, members: []) } + shared)
    }
    func filtered(kind: RecordKind?, date: Date?) -> [AccessibleRecord] {
        entries.filter { entry in
            let r = entry.record
            let mine = entry.family == nil || r.assignee.caseInsensitiveCompare(accountEmail) == .orderedSame || r.assignee == "Everyone"
            return (kind == nil || r.kind == kind) && (!mineOnly || mine) && (!pendingOnly || !r.completed)
                && (date == nil || Calendar.current.isDate(r.date, inSameDayAs: date!))
        }.sorted { $0.record.date < $1.record.date }
    }
    func refresh() async {
        guard isActive, !loading else { return }
        loading = true; error = nil; shared = []
        defer { loading = false }
        guard accountSignedIn else { return }
        let scope = accountDataScope
        do {
            let api = FamilyAPI(account: account)
            let families = try await api.families()
            var values: [AccessibleRecord] = []
            for family in families {
                do {
                    async let records = api.records(familyID: family.id)
                    async let members = api.members(familyID: family.id)
                    let pair = try await (records, members)
                    values += pair.0.map { AccessibleRecord(record: $0, family: family, members: pair.1) }
                } catch {
                    guard isCurrent(scope) else { return }
                    self.error = "Some households could not load. Refresh to check access and connection."
                }
            }
            guard isCurrent(scope) else { return }
            shared = AccessibleRecord.unique(values)
        } catch { if isCurrent(scope) { self.error = error.localizedDescription } }
    }
    func save(_ record: HouseholdRecord, source: AccessibleRecord) async throws {
        guard isActive else { throw CancellationError() }
        if let family = source.family {
            try await FamilyAPI(account: account).save(record, familyID: family.id)
            if context?.family?.id == family.id { await context?.refresh() }
        } else if !store.upsert(record) { throw FamilyError.invalid(store.error ?? "Could not save record.") }
        await refresh()
    }
}

@MainActor
final class RecordsViewModel: ScreenViewModel {
    let kind: RecordKind
    @Published var search = ""
    @Published var selected: HouseholdRecord?
    @Published var creating = false
    @Published var scanning = false
    @Published var showCompleted = true
    @Published var taskFilter: TaskFilter = .all
    @Published var billFilter: BillFilter = .all

    var filtered: [HouseholdRecord] {
        activeRecords.filter {
            matchesSelectedKind($0) &&
            (kind != .task || taskFilter.includes($0, shared: context?.family != nil, accountEmail: account.email, localName: profile.name)) &&
            (kind != .bill || billFilter.includes($0)) &&
            (kind == .bill || showCompleted || !$0.completed) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }.sorted { a, b in
            if kind == .expense {
                return (ExpenseIntelligence.spendingDate(for: a) ?? a.date) > (ExpenseIntelligence.spendingDate(for: b) ?? b.date)
            }
            if kind == .task, taskFilter == .all, a.priority != b.priority { return a.priority > b.priority }
            return a.completed != b.completed ? !a.completed : a.date < b.date
        }
    }
    var open: Int { activeRecords.filter { matchesSelectedKind($0) && !$0.completed }.count }
    var spendingThisMonth: Double { monthlyExpenses.reduce(0) { $0 + $1.amount } }
    var unpaidBills: Double { activeRecords.filter { $0.kind == .bill && !$0.completed }.reduce(0) { $0 + $1.amount } }
    var paidBillsThisMonth: Double {
        monthlyExpenses.filter { $0.kind == .bill }.reduce(0) { $0 + $1.amount }
    }

    private func matchesSelectedKind(_ record: HouseholdRecord) -> Bool {
        return record.kind == kind
    }

    init(store: HouseholdStore, account: CloudAccount, kind: RecordKind, context: HouseholdContext? = nil) {
        self.kind = kind
        super.init(store: store, account: account, context: context)
    }

}
